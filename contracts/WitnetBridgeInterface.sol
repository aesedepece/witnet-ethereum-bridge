pragma solidity ^0.5.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "vrf-solidity/contracts/VRF.sol";

import "./BlockRelay.sol";


/**
 * @title Witnet Bridge Interface
 * @notice Contract to bridge requests to Witnet
 * @dev This contract enables posting requests that Witnet bridges will insert into the Witnet network
  * The result of the requests will be posted back to this contract by the bridge nodes too.
 * @author Witnet Foundation
 */
contract WitnetBridgeInterface is VRF {

  using SafeMath for uint256;

  struct DataRequest {
    bytes dr;
    uint256 inclusionReward;
    uint256 tallyReward;
    bytes result;
    uint256 timestamp;
    uint256 drHash;
    address payable pkhClaim;
  }

  BlockRelay blockRelay;

  DataRequest[] public requests;

  // Event emitted when a new DR is posted
  event PostedRequest(address indexed _from, uint256 _id);

  // Event emitted when a DR inclusion proof is posted
  event IncludedRequest(address indexed _from, uint256 _id);

  // Event emitted when a result proof is posted
  event PostedResult(address indexed _from, uint256 _id);

  // Ensures the reward is not greater than the value
  modifier payingEnough(uint256 _value, uint256 _tally) {
    require(_value >= _tally, "Transaction value needs to be equal or greater than tally reward");
    _;
  }

  // Ensures the poe is valid
  modifier poeValid(
    uint256[4] memory _poe,
    uint256[2] memory _publicKey,
    uint256[2] memory _uPoint,
    uint256[4] memory _vPointHelpers) {
    require(verifyPoe(_poe, _publicKey, _uPoint, _vPointHelpers) == true, "Not a valid PoE");
    _;
  }

  // Ensures signature (sign(msg.sender)) is valid
  modifier validSignature(
    uint256[2] memory _publicKey,
    bytes memory addrSignature) {
    require(verifySig(abi.encodePacked(msg.sender), _publicKey, addrSignature) == true, "Not a valid signature");
    _;
  }

  // Ensures the DR inclusion proof has not been reported yet
  modifier drNotIncluded(uint256 _id) {
    require(requests[_id].drHash == 0, "DR already included");
    _;
  }

  // Ensures the DR inclusion has been already reported
  modifier drIncluded(uint256 _id) {
    require(requests[_id].drHash != 0, "DR not yet included");
    _;
  }
  // Ensures the result has not been reported yet
  modifier resultNotIncluded(uint256 _id) {
    require(requests[_id].result.length == 0, "Result already included");
    _;
  }

  constructor (address _blockRelayAddress) public {
    blockRelay = BlockRelay(_blockRelayAddress);
  }

  /// @dev Posts a data request into the WBI in expectation that it will be relayed and resolved in Witnet with a total reward that equals to msg.value.
  /// @param _dr The bytes corresponding to the Protocol Buffers serialization of the data request output.
  /// @param _tallyReward The amount of value that will be detracted from the transaction value and reserved for rewarding the reporting of the final result (aka tally) of the data request.
  /// @return The unique identifier of the data request.
  function postDataRequest(bytes memory _dr, uint256 _tallyReward)
    public
    payable
    payingEnough(msg.value, _tallyReward)
  returns(uint256 _id) {
    _id = requests.length;
    DataRequest memory dr;
    requests.push(dr);

    requests[_id].dr = _dr;
    requests[_id].inclusionReward = msg.value - _tallyReward;
    requests[_id].tallyReward = _tallyReward;
    requests[_id].result = "";
    requests[_id].timestamp = 0;
    requests[_id].drHash = 0;
    requests[_id].pkhClaim = address(0);
    emit PostedRequest(msg.sender, _id);
    return _id;
  }

  /// @dev Increments the rewards of a data request by adding more value to it. The new request reward will be increased by msg.value minus the difference between the former tally reward and the new tally reward.
  /// @param _id The unique identifier of the data request.
  /// @param _tallyReward The new tally reward. Needs to be equal or greater than the former tally reward.
  function upgradeDataRequest(uint256 _id, uint256 _tallyReward)
    public
    payable
    payingEnough(msg.value, _tallyReward)
  {
    requests[_id].inclusionReward += msg.value - _tallyReward;
    requests[_id].tallyReward += _tallyReward;
  }

  /// @dev Claim drs to be posted to Witnet by the node
  /// @param _ids Data request ids to be claimed
  /// @param _poe PoE claiming eligibility
  /// @param _uPoint uPoint coordinates as [uPointX, uPointY] corresponding to U = s*B - c*Y
  /// @param _vPointHelpers helpers for calculating the V point as [(s*H)X, (s*H)Y, cGammaX, cGammaY]. V = s*H + cGamma
  function claimDataRequests(
    uint256[] memory _ids,
    uint256[4] memory _poe,
    uint256[2] memory _publicKey,
    uint256[2] memory _uPoint,
    uint256[4] memory _vPointHelpers,
    bytes memory addrSignature)
    public
    validSignature(_publicKey, addrSignature)
    poeValid(_poe,_publicKey, _uPoint,_vPointHelpers)
    returns(bool)
  {
    for (uint i = 0; i < _ids.length; i++) {
      uint256 index = _ids[i];
      if((requests[index].timestamp == 0 || block.number - requests[index].timestamp > 13) &&
      requests[index].drHash == 0 &&
      requests[index].result.length == 0){
        requests[index].pkhClaim = msg.sender;
        requests[index].timestamp = block.number;
      }
      else{
        revert("One of the listed data requests was already claimed");
      }
    }
    return true;
  }

  /// @dev Checks if the data requests from a list are claimable or not.
  /// @param _ids The list of data request identifiers to be checked.
  /// @return An array of booleans indicating if data request are claimable or not.
  function checkDataRequestsClaimability(uint256[] memory _ids) public view returns (bool[] memory) {
    bool[] memory validIds = new bool[](_ids.length);
    for (uint i = 0; i < _ids.length; i++) {
      uint256 index = _ids[i];
      validIds[i] = (requests[index].timestamp == 0 || block.number - requests[index].timestamp > 13) &&
        requests[index].drHash == 0 &&
        requests[index].result.length == 0;
    }

    return validIds;
  }

  /// @dev Presents a proof of inclusion to prove that the request was posted into Witnet so as to unlock the inclusion reward that was put aside for the claiming identity (public key hash).
  /// @param _id The unique identifier of the data request.
  /// @param _poi A proof of inclusion proving that the data request appears listed in one recent block in Witnet.
  /// @param _index The index in the merkle tree.
  /// @param _blockHash The hash of the block in which the data request was inserted.
  function reportDataRequestInclusion (
    uint256 _id,
    uint256[] memory _poi,
    uint256 _index,
    uint256 _blockHash
    )
    public
    drNotIncluded(_id)
 {
    uint256 drRoot = blockRelay.readDrMerkleRoot(_blockHash);
    uint256 drOutputHash = uint256(sha256(requests[_id].dr));
    uint256 drHash = uint256(sha256(abi.encodePacked(drOutputHash, _poi[0])));
    if (verifyPoi(_poi, drRoot, _index, drOutputHash)) {
      requests[_id].drHash = drHash;
      requests[_id].pkhClaim.transfer(requests[_id].inclusionReward);
      emit IncludedRequest(msg.sender, _id);
    } else {
      revert("Invalid PoI");
    }
  }

  /// @dev Reports the result of a data request in Witnet.
  /// @param _id The unique identifier of the data request.
  /// @param _poi A proof of inclusion proving that the data in _result has been acknowledged by the Witnet network as being the final result for the data request by putting in a tally transaction inside a Witnet block.
  /// @param _index The position of the tally transaction in the tallies-only merkle tree in the Witnet block.
  /// @param _blockHash The hash of the block in which the result (tally) was inserted.
  /// @param _result The result itself as bytes.
  function reportResult (
    uint256 _id,
    uint256[] memory _poi,
    uint256 _index,
    uint256 _blockHash,
    bytes memory _result
    )
    public
    drIncluded(_id)
    resultNotIncluded(_id)
 {
    uint256 tallyRoot = blockRelay.readTallyMerkleRoot(_blockHash);
    // this should leave it ready for PoI
    uint256 resHash = uint256(sha256(abi.encodePacked(requests[_id].drHash, _result)));
    if (verifyPoi(_poi, tallyRoot, _index, resHash)){
      requests[_id].result = _result;
      msg.sender.transfer(requests[_id].tallyReward);
      emit PostedResult(msg.sender, _id);
    }
    else{
      revert("Invalid PoI");
    }
  }

  /// @dev Retrieves the bytes of the serialization of one data request from the WBI.
  /// @param _id The unique identifier of the data request.
  /// @return The result of the data request as bytes.
  function readDataRequest (uint256 _id) public view returns(bytes memory){
    return requests[_id].dr;
  }

  /// @dev Retrieves the result (if already available) of one data request from the WBI.
  /// @param _id The unique identifier of the data request.
  /// @return The result of the DR
  function readResult (uint256 _id) public view returns(bytes memory){
    return requests[_id].result;
  }

  /// @dev Retrieves hash of the data request transaction in Witnet
  /// @param _id The unique identifier of the data request.
  /// @return The hash of the DataRequest transaction in Witnet
  function readDrHash (uint256 _id) public view returns(uint256){
    return requests[_id].drHash;
  }

  /// @dev Number of data requests in the WBI.
  /// @return Returns the number of data requests in the WBI.
  function requestsCount() public view returns(uint256){
    return requests.length;
  }

  /// @dev Read the beacon of the last block inserted
  /// @return bytes to be signed by the node as PoE
  function getLastBeacon()
    public
    view
  returns(bytes memory)
  {
    return blockRelay.getLastBeacon();
  }

  /// @dev Claim drs to be posted to Witnet by the node
  /// @param _poe PoE claiming eligibility
  /// @param _publicKey The public key as an array composed of `[pubKey-x, pubKey-y]`
  /// @param _uPoint uPoint coordinates as [uPointX, uPointY] corresponding to U = s*B - c*Y
  /// @param _vPointHelpers helpers for calculating the V point as [(s*H)X, (s*H)Y, cGammaX, cGammaY]. V = s*H + cGamma
  function verifyPoe(
    uint256[4] memory _poe,
    uint256[2] memory _publicKey,
    uint256[2] memory _uPoint,
    uint256[4] memory _vPointHelpers)
  internal view returns(bool) {
    bytes memory message = getLastBeacon();

    return fastVerify(
      _publicKey,
      _poe,
      message,
      _uPoint,
      _vPointHelpers);
  }

  /// @dev Verifies the validity of a PoI
  /// @param _poi the proof of inclusion as [leaf1, leaf2,..]
  /// @param _root the merkle root
  /// @param _index the index in the merkle tree of the element to verify
  /// @param _element the element
  /// @return true or false depending the validity
  function verifyPoi(
    uint256[] memory _poi,
    uint256 _root,
    uint256 _index,
    uint256 _element)
  internal pure returns(bool){
    uint256 tree = _element;
    uint256 index = _index;
    for (uint i = 0; i<_poi.length; i++){
      if(index%2 == 0){
        tree = uint256(sha256(abi.encodePacked(tree, _poi[i])));
      }
      else{
        tree = uint256(sha256(abi.encodePacked(_poi[i], tree)));
      }
      index = index>>1;
    }
    return _root==tree;
  }

  /// @dev Verifies the validity of a signature
  /// @param _message message to be verified
  /// @param _publicKey public key of the signer as `[pubKey-x, pubKey-y]`
  /// @param _addrSignature the signature to verify asas r||s||v
  /// @return true or false depending the validity
  function verifySig(
    bytes memory _message,
    uint256[2] memory _publicKey,
    bytes memory _addrSignature
    )
  internal returns(bool){
    bytes32 r;
    bytes32 s;
    uint8 v;
    assembly {
            r := mload(add(_addrSignature, 0x20))
            s := mload(add(_addrSignature, 0x40))
            v := byte(0, mload(add(_addrSignature, 0x60)))
    }

    if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
      return false;
    }

    if (v != 0 && v != 1) {
      return false;
    }
    v = 28 - v;

    bytes32 msg_hash = sha256(_message);
    address hashed_key = pointToAddress(_publicKey[0], _publicKey[1]);
    return ecrecover(msg_hash, v, r, s) == hashed_key;
  }
}

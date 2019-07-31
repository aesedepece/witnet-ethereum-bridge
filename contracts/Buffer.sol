pragma solidity ^0.5.0;

library Buffer {
    struct buffer {
        bytes data;
        uint16 cursor;
    }

    function read(buffer memory self, uint64 _length) internal pure returns(bytes memory){
        require(self.cursor + _length <= self.data.length, "Not enough bytes in buffer");
        bytes memory value = new bytes(_length);
        for (uint64 index = 0; index < _length; index++) {
            value[index] = self.data[self.cursor];
            self.cursor++;
        }
        return value;
    }

    function readUint8(Buffer.buffer memory self) internal pure returns(uint8) {
        return uint8(read(self, 1)[0]);
    }

    function readUint16(Buffer.buffer memory self) internal pure returns(uint16) {
        bytes memory bytesValue = read(self, 2);
        return (uint16(uint8(bytesValue[0])) << 8)
        | uint8(bytesValue[1]);
    }

    function readUint32(Buffer.buffer memory self) internal pure returns(uint32) {
        bytes memory bytesValue = read(self, 4);
        return (uint32(uint8(bytesValue[0])) << 24)
        | (uint32(uint8(bytesValue[1])) << 16)
        | (uint16(uint8(bytesValue[2])) << 8)
        | uint8(bytesValue[3]);
    }

    function readUint64(Buffer.buffer memory self) internal pure returns(uint64) {
        bytes memory bytesValue = read(self, 8);
        return (uint64(uint8(bytesValue[0])) << 56)
        | (uint64(uint8(bytesValue[1])) << 48)
        | (uint64(uint8(bytesValue[2])) << 40)
        | (uint64(uint8(bytesValue[3])) << 32)
        | (uint32(uint8(bytesValue[4])) << 24)
        | (uint32(uint8(bytesValue[5])) << 16)
        | (uint16(uint8(bytesValue[6])) << 8)
        | uint8(bytesValue[7]);
    }

    function readFloat16(Buffer.buffer memory self) internal pure returns(int32) {
        uint32 bytesValue = readUint16(self);
        uint32 sign = bytesValue & 0x8000;
        int32 exponent = (int32(bytesValue & 0x7c00) >> 10) - 15;
        int32 fraction = int32(bytesValue & 0x03ff);
        if (exponent == 15) {
            fraction |= 0x400;
        }

        int32 result = 0;
        if (exponent >= 0) {
            result = int32(((1 << uint256(exponent)) * 10000 * (uint256(fraction) | 0x400)) >> 10);
        } else {
            result = int32((((uint256(fraction) | 0x400) * 10000) / (1 << uint256(-exponent))) >> 10);
        }

        if (sign != 0) {
            result *= -1;
        }
        return result;
    }
}

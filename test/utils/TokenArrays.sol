// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

library TokenArrays {
    function createTwoTokenArray(address _t0, address _t1, bool isSort) internal pure returns (address[] memory) {
        address[] memory tokenArray = new address[](2);
        tokenArray[0] = _t0;
        tokenArray[1] = _t1;

        return isSort ? sortTokenArray(tokenArray) : tokenArray;
    }

    function createThreeTokenArray(
        address _t0,
        address _t1,
        address _t2,
        bool isSort
    ) internal pure returns (address[] memory) {
        address[] memory tokenArray = new address[](3);
        tokenArray[0] = _t0;
        tokenArray[1] = _t1;
        tokenArray[2] = _t2;

        return isSort ? sortTokenArray(tokenArray) : tokenArray;
    }

    function sortTokenArray(address[] memory _tokenArray) internal pure returns (address[] memory) {
        for (uint i = 0; i < _tokenArray.length - 1; i++) {
            if (_tokenArray[i] > _tokenArray[i + 1]) {
                (_tokenArray[i], _tokenArray[i + 1]) = (_tokenArray[i + 1], _tokenArray[i]);
            }
        }

        return _tokenArray;
    }

    function createValueList(uint256 _v0) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = _v0;

        return arr;
    }

    function createValueList(uint256 _v0, uint256 _v1) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](2);
        arr[0] = _v0;
        arr[1] = _v1;

        return arr;
    }

    function createValueList(uint256 _v0, uint256 _v1, uint256 _v2) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](3);
        arr[0] = _v0;
        arr[1] = _v1;
        arr[2] = _v2;

        return arr;
    }
}

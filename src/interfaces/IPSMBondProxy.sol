// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;

interface IPSMBondProxy {
    function deposit(uint256 amount, address receiver) external returns (uint256);
}

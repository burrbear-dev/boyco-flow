// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;

interface IHoneyFactory {
    function honey() external view returns (address);
    function mintRates(address asset) external view returns (uint256);
    function mint(address asset, uint256 amount, address receiver, bool expectBasketMode) external returns (uint256);
}

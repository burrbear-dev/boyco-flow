// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";

interface IDepositLocker {
    function bridgeSingleTokens(bytes32 marketHash, address[] memory depositors) external payable;
}

contract BridgeTokensScript is Script, Test {
    // --- sepolia addresses ---
    address constant MARKET_OWNER = 0x235A2ac113014F9dcb8aBA6577F20290832dDEFd;
    address constant DEPOSIT_LOCKER = 0x0bef4676900f89Ce8d31f4255E3F506f32acd4cB;
    bytes32 constant MARKET_HASH = 0x14a40bc60f69c582d9e664a2a03765b1dd6182296c42ef7eb2d71eefcd7825c4;
    uint256 constant ETH_FOR_GAS = 0.5 ether;

    function run() public {
        vm.startBroadcast();
        // ensure we pass the correct `--account` and `--sender` to forge script command
        require(msg.sender == MARKET_OWNER, "Only the market owner can bridge tokens");

        address[] memory depositors = new address[](2);
        depositors[0] = 0x15f05Cd06fa979b311B5282724A9A8f1b4B9532A;
        depositors[1] = 0x235A2ac113014F9dcb8aBA6577F20290832dDEFd;
        IDepositLocker(DEPOSIT_LOCKER).bridgeSingleTokens{value: ETH_FOR_GAS}(MARKET_HASH, depositors);

        vm.stopBroadcast();
    }
}

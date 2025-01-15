// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {IERC20} from "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";

import {BoycoBurrZap} from "../src/BoycoBurrZap.sol";

contract BoycoBurrZapScript is Script, Test {
    // cArtio environment
    address constant VAULT = 0x398D4CFB5D29d18BaA149497656904F2e8814EFb;
    address constant NECT_USDC_HONEY_POOL = 0xFbb99BAD8eca0736A9ab2a7f566dEbC9acb607f0;
    address constant USDC = 0x015fd589F4f1A33ce4487E12714e1B15129c9329;
    address constant HONEY_FACTORY = 0xA81F0019d442f19f66880bcf2698B4E5D5Ec249A;
    address constant BALANCER_QUERIES = 0x4475Ba7AfdCfC0ED90772843A106b2C77395f19C;
    // ---- BeraBorrow related addresses ----
    address constant NECT = 0xefEeD4d987F6d1dE0f23D116a578402456819C28;
    address constant PSM_BOND_PROXY = 0xd064C80776497821313b1Dc0E3192d1a67b2a9fa;

    function run() public {
        vm.startBroadcast();
        // cartio deployment
        BoycoBurrZap zap =
            new BoycoBurrZap(USDC, NECT_USDC_HONEY_POOL, BALANCER_QUERIES, HONEY_FACTORY, NECT, PSM_BOND_PROXY);
        // whitelist sender
        zap.whitelist(msg.sender);
        vm.stopBroadcast();

        // ensure queryDeposit works
        zap.queryDeposit(1e6, msg.sender);
    }
}

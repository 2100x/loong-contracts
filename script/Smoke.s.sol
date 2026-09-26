// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LoongLaunchFactory} from "../src/LoongLaunchFactory.sol";
import {LoongBondingCurve} from "../src/LoongBondingCurve.sol";
import {LaunchAndBuy} from "../src/LaunchAndBuy.sol";
import {GraduationPhase} from "../src/interfaces/ILaunchpadV2.sol";
import {LoongVanity} from "./LoongVanity.sol";

/**
 * TESTNET smoke run against a fresh deployment: launch (with an opening buy, through the router) on the
 * tiny test config -> sell a little on the curve -> buy the rest -> graduation sweep -> seed the Infinity pool.
 *
 *   DEPLOYER_PK=... forge script script/Smoke.s.sol --rpc-url $RPC --broadcast --slow
 */
contract Smoke is Script {
    uint256 constant TEST_CONFIG = 1; // 0.1 BNB graduation, testnet only

    function run() external {
        require(block.chainid != 56, "smoke run is testnet-only");
        string memory d = vm.readFile(string.concat("../deployments/", vm.toString(block.chainid), ".json"));
        LoongLaunchFactory factory = LoongLaunchFactory(payable(vm.parseJsonAddress(d, ".factory")));
        LaunchAndBuy router = LaunchAndBuy(payable(vm.parseJsonAddress(d, ".launchAndBuy")));
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address me = vm.addr(pk);

        LoongLaunchFactory.TokenParams memory p;
        p.name = "Loong Smoke Test";
        p.symbol = string.concat("SMK", vm.toString(block.timestamp % 10000));
        p.description = "Testnet smoke run of the Loong launchpad.";
        p.creatorFeeRecipient = me;
        p.buybackEnabled = true;
        p.expectedEconomics = factory.previewLaunchEconomics(TEST_CONFIG, address(0));
        p.salt = LoongVanity.mine(factory, p, TEST_CONFIG, address(0), me);

        vm.startBroadcast(pk);
        (address token, address curveAddr,) =
            router.launchAndBuy{value: 0.02 ether}(p, TEST_CONFIG, address(0), 0.02 ether, 1, me, false);
        LoongBondingCurve curve = LoongBondingCurve(payable(curveAddr));

        uint256 bal = IERC20(token).balanceOf(me);
        IERC20(token).approve(curveAddr, bal / 4);
        curve.sell(bal / 4, 1, me);

        curve.buy{value: 0.15 ether}(0.15 ether, 1, me); // overbuys the 0.1 BNB curve; the excess is refunded
        vm.stopBroadcast();

        require(uint16(uint160(token)) == 0x9999, "token not on a ...9999 address");
        GraduationPhase ph = factory.getLaunchedToken(token).phase;
        console2.log("token", token);
        console2.log("phase after completing buy (1 = Swept)", uint8(ph));

        if (ph == GraduationPhase.Swept) {
            vm.broadcast(pk);
            factory.createGraduatedPool(token);
            console2.log("phase after createGraduatedPool (2 = PoolCreated)", uint8(factory.getLaunchedToken(token).phase));
            console2.logBytes32(factory.poolIdFor(token));
        }
    }
}

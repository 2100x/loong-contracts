// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LoongLaunchFactory} from "../src/LoongLaunchFactory.sol";
import {LaunchAndBuy} from "../src/LaunchAndBuy.sol";
import {LoongVanity} from "./LoongVanity.sol";
import {MockStock} from "./MockStock.sol";

/// Testnet: launch a coin quoted in a mock stock token (PAIR), with a small first buy paid in that token.
contract TinyPair is Script {
    function run() external {
        require(block.chainid != 56, "testnet only");
        string memory d = vm.readFile(string.concat("../deployments/", vm.toString(block.chainid), ".json"));
        LoongLaunchFactory factory = LoongLaunchFactory(payable(vm.parseJsonAddress(d, ".factory")));
        LaunchAndBuy router = LaunchAndBuy(payable(vm.parseJsonAddress(d, ".launchAndBuy")));
        address pair = vm.envAddress("PAIR");
        uint256 firstBuy = vm.envUint("FIRST_BUY");
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address me = vm.addr(pk);
        LoongLaunchFactory.TokenParams memory p;
        p.name = vm.envOr("NAME", string("Loong Pair Test"));
        p.symbol = string.concat("PT", vm.toString(block.timestamp % 10000));
        p.description = "Stock-quoted launch test.";
        p.creatorFeeRecipient = me;
        p.buybackEnabled = true;
        p.expectedEconomics = factory.previewLaunchEconomics(0, pair);
        p.salt = LoongVanity.mine(factory, p, 0, pair, me);
        vm.startBroadcast(pk);
        MockStock(pair).mint(me, firstBuy);
        IERC20(pair).approve(address(router), firstBuy);
        (address token,,) = router.launchAndBuy(p, 0, pair, firstBuy, 1, me, false);
        vm.stopBroadcast();
        console2.log("token", token);
    }
}

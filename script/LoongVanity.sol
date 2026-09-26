// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LoongLaunchFactory} from "../src/LoongLaunchFactory.sol";
import {LoongBondingCurve} from "../src/LoongBondingCurve.sol";
import {LoongLauncherToken} from "../src/LoongLauncherToken.sol";
import {LaunchDeployment} from "../src/LoongLaunchDeployer.sol";
import {ILoongFeePolicy} from "../src/interfaces/ILaunchpadV2.sol";

/**
 * Finds a CREATE2 salt that puts a launch's token on a ...9999 address, mirroring LoongLaunchDeployer
 * exactly. Everything is read from the live factory, so the same code serves tests, scripts and as the
 * reference for the website's in-browser miner.
 *
 * The curve's init code does not depend on the salt, so its hash is computed once. The token's init code
 * embeds the curve address (7th head word of its constructor args), which is patched in place each round.
 * The loop allocates nothing: ~65k rounds on average, and any per-round allocation compounds into MemoryOOG.
 */
library LoongVanity {
    uint16 internal constant SUFFIX = 0x9999;

    function mine(LoongLaunchFactory factory, LoongLaunchFactory.TokenParams memory p, uint256 configId, address pairToken, address launcher)
        internal
        view
        returns (bytes32)
    {
        LaunchDeployment memory d = deployment(factory, p, configId, pairToken, launcher);
        bytes32 curveHash = keccak256(
            abi.encodePacked(
                type(LoongBondingCurve).creationCode,
                abi.encode(
                    d.pairToken, d.creatorFeeRecipient, address(factory), d.feePolicy, d.policy, d.feeEscrow,
                    d.buybackVault, d.phantomQuote, d.curveFeeBps, d.creatorTaxBps, d.buybackEnabled, d.graduationThreshold
                )
            )
        );
        bytes memory args =
            abi.encode(d.name, d.symbol, d.logo, d.description, d.socials, launcher, address(0), address(factory), d.supply);
        bytes memory init = abi.encodePacked(type(LoongLauncherToken).creationCode, args);
        uint256 slot = init.length - args.length + 6 * 32;
        address deployer = address(factory.launchDeployer());

        // Guard the hand-rolled derivation against the deployer's own view once before trusting the loop.
        d.salt = bytes32(uint256(7));
        (address expect,) = factory.launchDeployer().predictLaunchAddresses(d);
        require(tokenAt(launcher, d.salt, curveHash, init, deployer, slot) == expect, "vanity: derivation drifted");

        for (uint256 i = 1;; ++i) {
            if (uint16(uint160(tokenAt(launcher, bytes32(i), curveHash, init, deployer, slot))) == SUFFIX) return bytes32(i);
        }
    }

    /// The LaunchDeployment the factory will build for these params, with salt left zero.
    function deployment(LoongLaunchFactory factory, LoongLaunchFactory.TokenParams memory p, uint256 configId, address pairToken, address launcher)
        internal
        view
        returns (LaunchDeployment memory d)
    {
        LoongLaunchFactory.LaunchConfig memory c = factory.getLaunchConfig(configId);
        if (pairToken == address(0)) {
            (d.phantomQuote, d.graduationThreshold) = (c.phantomQuote, c.graduationThreshold);
        } else {
            (d.phantomQuote, d.graduationThreshold,) = factory.pairTokenEconomics(pairToken);
        }
        d.pairToken = pairToken;
        d.creatorFeeRecipient = p.creatorFeeRecipient == address(0) ? launcher : p.creatorFeeRecipient;
        d.originalDeployer = launcher;
        d.feePolicy = ILoongFeePolicy(address(factory.memeHook()));
        d.policy = factory.memeHook().currentFeePolicy();
        d.feeEscrow = factory.feeEscrow();
        d.buybackVault = factory.buybackVault();
        d.curveFeeBps = c.curveFeeBps;
        d.creatorTaxBps = p.creatorTaxBps;
        d.buybackEnabled = p.buybackEnabled;
        d.supply = c.supply;
        d.name = p.name;
        d.symbol = p.symbol;
        d.logo = p.logo;
        d.description = p.description;
        d.socials = p.socials;
    }

    function tokenAt(address launcher, bytes32 salt, bytes32 curveHash, bytes memory init, address deployer, uint256 slot)
        internal
        pure
        returns (address tk)
    {
        assembly {
            let buf := mload(0x40) // scratch above the free pointer, never claimed
            mstore(buf, launcher)
            mstore(add(buf, 0x20), salt)
            let s := keccak256(buf, 0x40) // keccak256(abi.encode(launcher, salt))
            mstore8(buf, 0xff)
            mstore(add(buf, 0x01), shl(96, deployer))
            mstore(add(buf, 0x15), s)
            mstore(add(buf, 0x35), curveHash)
            let cv := and(keccak256(buf, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
            mstore(add(add(init, 32), slot), cv)
            let initHash := keccak256(add(init, 32), mload(init))
            mstore8(buf, 0xff)
            mstore(add(buf, 0x01), shl(96, deployer))
            mstore(add(buf, 0x15), s)
            mstore(add(buf, 0x35), initHash)
            tk := and(keccak256(buf, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}

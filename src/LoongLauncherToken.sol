// SPDX-License-Identifier: MIT
// Modifications Copyright (c) 2026 Genius
// Modifications Copyright (c) 2026 Loong: renamed from Genius; Loong's changes are listed in README.md.
// Original notices above are retained as the licence requires.
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title LoongLauncherToken
 * @notice Non-mintable ERC-20 deployed by LoongLaunchFactory for a v2 launch.
 * The entire supply mints once, in this constructor, directly to the token's
 * bonding curve instead of a Uniswap position, and nothing can mint again.
 * Anyone, the deployer included, may buy any amount from the curve at any
 * time; the curve's own price impact and its reserved pool
 * allocation are the only limits on a large buy. `deployer` is carried here
 * as immutable reference data for off-chain attribution only, and confers no
 * privileges over the token.
 * Supply is never fixed on any launch. `ERC20Burnable` gives every holder a
 * public `burn`, and a `burnFrom` against any allowance they hold, so
 * `totalSupply()` can fall on a legacy and a Foundation launch alike; it can
 * only ever fall, since nothing here can mint. `ERC20Burnable` is also what
 * the Foundation fee policy's buyback leg calls, from
 * `LoongBondingCurve._sweepFoundationFees` before graduation and
 * `LoongMemeHook._sweepFoundationPool` after it, to destroy the tokens that
 * leg buys back. Under the legacy fee policy that leg burns nothing:
 * bought-back tokens are locked into `LoongBuybackVault` for a five-year
 * vest. The difference is therefore in protocol action, not in whether supply
 * can change: a legacy launch's supply is free of protocol buyback burns and
 * moves only when holders burn voluntarily, while a Foundation launch's
 * `totalSupply()` also shrinks under the protocol's own buyback-and-burn.
 * Because either kind of burn moves `totalSupply()`, the stable reference for
 * the supply a launch was configured around is
 * `LoongBondingCurve.launchSupply`, which is recorded at initialize on every
 * launch and is what graduation-allocation accounting reads.
 */
contract LoongLauncherToken is ERC20, ERC20Burnable {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    error ZeroAddress();

    address public immutable deployer;
    address public immutable launchFactory;
    address public immutable curve;

    string public logo;
    string public description;

    Socials private _socials;

    /**
     * @notice Creates a v2 launch token and mints its entire supply to the bonding curve.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        string memory logo_,
        string memory description_,
        Socials memory socials_,
        address deployer_,
        address curve_,
        address launchFactory_,
        uint256 supply_
    ) ERC20(name_, symbol_) {
        if (deployer_ == address(0) || curve_ == address(0) || launchFactory_ == address(0)) {
            revert ZeroAddress();
        }

        deployer = deployer_;
        // Passed explicitly rather than read from msg.sender: LoongLaunchFactory
        // deploys this token indirectly through LoongLaunchDeployer to keep its
        // own bytecode under EIP-170's size limit, so msg.sender at construction
        // time would otherwise resolve to that deployer helper, not the factory.
        launchFactory = launchFactory_;
        curve = curve_;
        logo = logo_;
        description = description_;
        _socials = socials_;

        _mint(curve_, supply_);
    }

    /**
     * @notice Returns the launch token's five social metadata fields.
     */
    function socials()
        external
        view
        returns (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        )
    {
        Socials memory values = _socials;
        return (values.twitter, values.telegram, values.discord, values.website, values.farcaster);
    }

    /**
     * @notice Returns creator and metadata in the launcher-compatible tuple.
     */
    function getTokenInfo()
        external
        view
        returns (
            address tokenDeployer,
            string memory tokenLogo,
            string memory tokenDescription,
            Socials memory tokenSocials
        )
    {
        return (deployer, logo, description, _socials);
    }
}

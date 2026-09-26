// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {LoongLaunchFactory} from "./LoongLaunchFactory.sol";
import {LoongBondingCurve} from "./LoongBondingCurve.sol";
import {GraduationPhase} from "./interfaces/ILaunchpadV2.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

interface IFoundationVault {
    function withdraw(address asset, uint256 amount) external;
    function controller() external view returns (address);
}

interface IUniversalRouterLike {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @title LoongBuybackBurner
 * @notice The foundation vault's controller: turns every platform-token share of the trading fees into $LOONG
 * and sends it to 0x…dEaD. Modelled on Pons's PONS buyback (read on chain 2026-09-24): small fixed chunks on a
 * fixed interval, a permissionless `poke()` that pays its caller a small tip, and a price guard so nobody can
 * push the price and then poke into it.
 *
 * Flow:
 *   1. `convert` (keeper or owner): pulls one non-BNB asset out of the vault and swaps it to BNB along a route
 *      the owner registered (PancakeSwap V3/V2 legs ending in WBNB, unwrapped). The keeper only picks the amount
 *      and the BNB minimum; it can never choose where the swap goes.
 *   2. `poke` (anyone while `openAccess`, otherwise keeper/owner): pulls the vault's BNB, buys $LOONG with at most
 *      `chunk` BNB (on its bonding curve before graduation, in its PancakeSwap Infinity pool after), sends every
 *      $LOONG it holds to the burn address, and tips the caller.
 *
 * Price guard: each buy must not be worse than the last buy's price by more than `maxDeviationBps`, plus
 * `driftBpsPerHour` for every hour since then (so a real, slow move up is followed, a same-block pump is not).
 * The first buy after `setLoong`, `resetReference` or $LOONG's graduation has no reference and only the chunk
 * size bounds it (graduation re-prices the coin by design; a curve price is no reference for the pool).
 *
 * On/off (Steven 2026-09-24): the burner starts PAUSED. Buybacks begin only when the owner calls `setLoong` and
 * `setPaused(false)`. The owner or a keeper can pause at any time (a keeper for emergencies); only the owner
 * can resume. While paused nothing leaves the vault except the owner's own `withdraw`; fees keep accumulating.
 *
 * Governance (Steven 2026-09-24, "flexible like Pons"): UUPS-upgradeable, and the owner can withdraw. The owner
 * must be the Safe multisig, never a single hot key: that is the difference from Pons, whose burner is owned
 * by a hot EOA. The vault's controller is immutable, so this proxy's address is permanent; only the
 * implementation behind it can change.
 */
contract LoongBuybackBurner is Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    // Universal Router commands / recipients (same bytes as SwapAndBuy's callers and the website use).
    bytes1 private constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 private constant V2_SWAP_EXACT_IN = 0x08;
    bytes1 private constant UNWRAP_WETH = 0x0c;
    bytes1 private constant INFI_SWAP = 0x10;
    address private constant MSG_SENDER = address(1);
    address private constant ADDRESS_THIS = address(2);
    uint256 private constant CONTRACT_BALANCE = 1 << 255;
    // Infinity actions: CL_SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL.
    bytes private constant INFI_BUY_ACTIONS = hex"060c0f";
    uint256 public constant MAX_DEVIATION_BPS = 5_000;
    uint256 public constant MAX_TIP = 0.01 ether;

    // Same layout as PancakeSwap Infinity's ICLRouterBase.CLSwapExactInputSingleParams (encoded as one tuple,
    // exactly what the website's routerSwap() sends).
    struct CLSwapExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct Leg {
        bool v2; // false: V3 packed path (token, fee, token, …); true: V2 address[] path
        bytes path; // V3: packed path. V2: abi.encode(address[])
    }

    struct Params {
        uint256 chunk; // max BNB per poke
        uint256 minBuy; // skip a poke with less BNB than this
        uint256 minInterval; // seconds between pokes
        uint256 tip; // BNB paid to the poker
        uint256 maxDeviationBps; // price guard vs the reference
        uint256 driftBpsPerHour; // how fast the allowed band widens after the last buy
        uint256 launchDelay; // seconds after $LOONG's launch before the first buy (clears the snipe-tax window)
        bool openAccess; // anyone may poke
    }

    // ---- storage (append only across upgrades) ----
    address public owner;
    address public pendingOwner;
    mapping(address => bool) public isKeeper;
    IFoundationVault public vault;
    LoongLaunchFactory public factory;
    IUniversalRouterLike public universalRouter;
    address public wbnb;
    address public loong;
    Params public params;
    uint256 public lastBuyAt;
    uint256 public refPrice; // BNB wei per 1e18 $LOONG, from the last buy
    mapping(address => Leg[]) private _routes;
    uint256 public totalBnbSpent;
    uint256 public totalBurned;
    uint256 private _locked;
    bool public paused;
    bool public refOnCurve; // the reference price came from a curve buy

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event KeeperSet(address indexed keeper, bool enabled);
    event LoongSet(address indexed token, address indexed curve);
    event ParamsSet(Params p);
    event RouteSet(address indexed asset, uint256 legs);
    event Converted(address indexed asset, uint256 amountIn, uint256 bnbOut);
    event BoughtAndBurned(address indexed caller, bool onCurve, uint256 bnbIn, uint256 loongBurned, uint256 price);
    event Tipped(address indexed caller, uint256 amount);
    event ReferenceReset(uint256 price);
    event Withdrawn(address indexed asset, address indexed to, uint256 amount);
    event PausedSet(address indexed by, bool paused);

    error NotOwner();
    error NotKeeper();
    error NotPendingOwner();
    error ZeroAddress();
    error Locked();
    error LoongNotSet();
    error NotBnbPaired();
    error TooSoon(uint256 nextAt);
    error NothingToBuy(uint256 bnb);
    error NotTradable();
    error PriceMoved(uint256 price, uint256 limit);
    error BadRoute();
    error NoRoute(address asset);
    error InsufficientBnbOut(uint256 got, uint256 minimum);
    error BadParams();
    error TransferFailed();
    error IsPaused();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != owner && !isKeeper[msg.sender]) revert NotKeeper();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier lock() {
        if (_locked == 1) revert Locked();
        _locked = 1;
        _;
        _locked = 0;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address keeper_,
        LoongLaunchFactory factory_,
        IUniversalRouterLike universalRouter_,
        address wbnb_,
        Params calldata p
    ) external initializer {
        if (owner_ == address(0) || address(factory_) == address(0) || address(universalRouter_) == address(0) || wbnb_ == address(0)) {
            revert ZeroAddress();
        }
        owner = owner_;
        factory = factory_;
        universalRouter = universalRouter_;
        wbnb = wbnb_;
        if (keeper_ != address(0)) {
            isKeeper[keeper_] = true;
            emit KeeperSet(keeper_, true);
        }
        _setParams(p);
        paused = true; // off until the owner decides when buybacks start
        emit PausedSet(owner_, true);
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @notice The foundation vault proves at construction that its controller accepts BNB (1 wei); after that
    /// the vault's own withdrawals, Universal Router unwraps and curve refunds arrive here.
    receive() external payable {}

    // ------------------------------------------------------------------ owner

    /// @notice Set once the vault exists (the vault is constructed with this proxy as its immutable controller,
    /// so it cannot be known at initialize time). Checks the vault really answers to this contract.
    function setVault(IFoundationVault vault_) external onlyOwner {
        if (vault_.controller() != address(this)) revert BadParams();
        vault = vault_;
    }

    /// @notice Point the burner at $LOONG once it is launched. It must be a BNB-paired coin of our own factory,
    /// so the curve and then the Infinity pool are the only markets the burner ever buys in.
    function setLoong(address token) external onlyOwner {
        LoongLaunchFactory.LaunchedToken memory launch = factory.getLaunchedToken(token);
        if (!launch.exists) revert LoongNotSet();
        if (launch.pairToken != address(0)) revert NotBnbPaired();
        loong = token;
        refPrice = 0;
        emit LoongSet(token, launch.curve);
    }

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    /// @notice Pause: owner or keeper (the keeper can stop things in an emergency). Resume: owner only.
    function setPaused(bool paused_) external {
        if (paused_) {
            if (msg.sender != owner && !isKeeper[msg.sender]) revert NotKeeper();
        } else if (msg.sender != owner) {
            revert NotOwner();
        }
        paused = paused_;
        emit PausedSet(msg.sender, paused_);
    }

    function setKeeper(address keeper, bool enabled) external onlyOwner {
        isKeeper[keeper] = enabled;
        emit KeeperSet(keeper, enabled);
    }

    /// @notice Registers how `asset` becomes BNB: legs chained asset -> … -> WBNB. Passing no legs removes it.
    function setRoute(address asset, Leg[] calldata legs) external onlyOwner {
        _setRoute(asset, legs);
    }

    function setRoutes(address[] calldata assets, Leg[][] calldata legs) external onlyOwner {
        if (assets.length != legs.length) revert BadParams();
        for (uint256 i; i < assets.length; ++i) {
            _setRoute(assets[i], legs[i]);
        }
    }

    /// @notice After a real, fast move (the guard then refuses every poke) the owner or keeper re-anchors on the
    /// next buy's price.
    function resetReference() external onlyKeeper {
        refPrice = 0;
        emit ReferenceReset(0);
    }

    /// @notice Owner escape hatch (the "flexible" choice): move any asset held here, or in the vault, to `to`.
    function withdraw(address asset, uint256 amount, address to, bool fromVault) external onlyOwner lock {
        if (to == address(0)) revert ZeroAddress();
        if (fromVault) vault.withdraw(asset, amount);
        _send(asset, to, amount);
        emit Withdrawn(asset, to, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ------------------------------------------------------------------ keeper

    /// @notice Pull `amount` of `asset` from the vault (0 = all of it) and swap it to BNB along its registered
    /// route. The BNB stays here for `poke`.
    function convert(address asset, uint256 amount, uint256 minBnbOut)
        external
        onlyKeeper
        whenNotPaused
        lock
        returns (uint256 bnbOut)
    {
        Leg[] storage legs = _routes[asset];
        if (legs.length == 0) revert NoRoute(asset);
        if (amount == 0) amount = IERC20(asset).balanceOf(address(vault));
        vault.withdraw(asset, amount);

        bytes memory commands = new bytes(legs.length + 1);
        bytes[] memory inputs = new bytes[](legs.length + 1);
        for (uint256 i; i < legs.length; ++i) {
            if (legs[i].v2) {
                commands[i] = V2_SWAP_EXACT_IN;
                inputs[i] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, uint256(0), abi.decode(legs[i].path, (address[])), false);
            } else {
                commands[i] = V3_SWAP_EXACT_IN;
                inputs[i] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE, uint256(0), legs[i].path, false);
            }
        }
        commands[legs.length] = UNWRAP_WETH;
        inputs[legs.length] = abi.encode(MSG_SENDER, minBnbOut);

        uint256 before = address(this).balance;
        IERC20(asset).safeTransfer(address(universalRouter), amount);
        universalRouter.execute(commands, inputs, block.timestamp);
        bnbOut = address(this).balance - before;
        if (bnbOut < minBnbOut || bnbOut == 0) revert InsufficientBnbOut(bnbOut, minBnbOut);
        emit Converted(asset, amount, bnbOut);
    }

    // ------------------------------------------------------------------ anyone

    /// @notice Buy $LOONG with up to `chunk` BNB and burn it. Anyone may call while `openAccess`; the caller is
    /// tipped `tip` BNB.
    function poke() external whenNotPaused lock returns (uint256 burned) {
        Params memory p = params;
        if (!p.openAccess && msg.sender != owner && !isKeeper[msg.sender]) revert NotKeeper();
        if (loong == address(0)) revert LoongNotSet();
        if (lastBuyAt != 0 && block.timestamp < lastBuyAt + p.minInterval) revert TooSoon(lastBuyAt + p.minInterval);

        uint256 vaultBnb = address(vault) == address(0) ? 0 : address(vault).balance;
        if (vaultBnb != 0) vault.withdraw(address(0), vaultBnb);

        uint256 bal = address(this).balance;
        uint256 reserve = p.tip;
        if (bal <= reserve || bal - reserve < p.minBuy) revert NothingToBuy(bal);
        uint256 amount = bal - reserve;
        if (amount > p.chunk) amount = p.chunk;

        (uint256 bought, bool onCurve, uint256 spent) = _buy(amount, p);
        uint256 price = (spent * 1e18) / bought;
        refPrice = price;
        refOnCurve = onCurve;
        lastBuyAt = block.timestamp;
        totalBnbSpent += spent;

        burned = IERC20(loong).balanceOf(address(this));
        IERC20(loong).safeTransfer(BURN, burned);
        totalBurned += burned;
        emit BoughtAndBurned(msg.sender, onCurve, spent, burned, price);

        if (p.tip != 0 && address(this).balance >= p.tip) {
            (bool ok,) = msg.sender.call{value: p.tip}("");
            if (ok) emit Tipped(msg.sender, p.tip);
        }
    }

    // ------------------------------------------------------------------ views

    function route(address asset) external view returns (Leg[] memory) {
        return _routes[asset];
    }

    /// @notice The worst price (BNB wei per 1e18 $LOONG) the next poke accepts; 0 = no reference yet.
    function priceLimit() public view returns (uint256) {
        if (refPrice == 0) return 0;
        Params memory p = params;
        uint256 dev = p.maxDeviationBps + (p.driftBpsPerHour * (block.timestamp - lastBuyAt)) / 1 hours;
        if (dev > MAX_DEVIATION_BPS) dev = MAX_DEVIATION_BPS;
        return (refPrice * (10_000 + dev)) / 10_000;
    }

    /// @notice When the next poke may run, and whether it has anything to spend. `nextAt` includes the wait
    /// after $LOONG's launch, so a keeper polling this never fires into a TooSoon.
    function status() external view returns (uint256 nextAt, uint256 bnbAvailable, uint256 limit) {
        nextAt = lastBuyAt == 0 ? 0 : lastBuyAt + params.minInterval;
        if (loong != address(0)) {
            LoongLaunchFactory.LaunchedToken memory launch = factory.getLaunchedToken(loong);
            if (launch.phase == GraduationPhase.NotGraduated) {
                uint256 ready = LoongBondingCurve(payable(launch.curve)).launchedAt() + params.launchDelay;
                if (ready > nextAt) nextAt = ready;
            }
        }
        bnbAvailable = address(this).balance + (address(vault) == address(0) ? 0 : address(vault).balance);
        limit = priceLimit();
    }

    // ------------------------------------------------------------------ internals

    function _buy(uint256 amount, Params memory p) private returns (uint256 bought, bool onCurve, uint256 spent) {
        LoongLaunchFactory.LaunchedToken memory launch = factory.getLaunchedToken(loong);
        uint256 limit = priceLimit();
        if (refOnCurve && launch.phase == GraduationPhase.PoolCreated) limit = 0; // first pool buy re-anchors
        uint256 minOut = limit == 0 ? 1 : (amount * 1e18) / limit;
        if (minOut == 0) minOut = 1;
        uint256 before = IERC20(loong).balanceOf(address(this));
        uint256 bnbBefore = address(this).balance;

        if (launch.phase == GraduationPhase.NotGraduated) {
            LoongBondingCurve curve = LoongBondingCurve(payable(launch.curve));
            if (curve.graduated()) revert NotTradable();
            uint256 launchedAt = curve.launchedAt();
            if (block.timestamp < launchedAt + p.launchDelay) revert TooSoon(launchedAt + p.launchDelay);
            // A buy that fills the curve is clamped and refunded by the curve; minOut is the price bound it checks.
            curve.buy{value: amount}(amount, minOut, address(this));
            onCurve = true;
        } else if (launch.phase == GraduationPhase.PoolCreated) {
            PoolKey memory key = factory.poolKeyFor(loong);
            // BNB is currency0 (address 0 sorts first), so buying $LOONG is zeroForOne.
            bytes[] memory params_ = new bytes[](3);
            params_[0] = abi.encode(CLSwapExactInputSingleParams(key, true, uint128(amount), uint128(minOut), bytes("")));
            params_[1] = abi.encode(address(0), amount);
            params_[2] = abi.encode(loong, minOut);
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = abi.encode(INFI_BUY_ACTIONS, params_);
            universalRouter.execute{value: amount}(abi.encodePacked(INFI_SWAP), inputs, block.timestamp);
        } else {
            revert NotTradable(); // swept, waiting for its pool
        }

        bought = IERC20(loong).balanceOf(address(this)) - before;
        spent = bnbBefore - address(this).balance;
        if (bought == 0 || spent == 0) revert NotTradable();
        if (limit != 0 && (spent * 1e18) / bought > limit) revert PriceMoved((spent * 1e18) / bought, limit);
    }

    function _setParams(Params calldata p) private {
        if (p.chunk == 0 || p.minBuy > p.chunk || p.tip > MAX_TIP || p.maxDeviationBps > MAX_DEVIATION_BPS) revert BadParams();
        params = p;
        emit ParamsSet(p);
    }

    function _setRoute(address asset, Leg[] calldata legs) private {
        delete _routes[asset];
        address cur = asset;
        for (uint256 i; i < legs.length; ++i) {
            (address first, address last) = legs[i].v2 ? _v2Ends(legs[i].path) : _v3Ends(legs[i].path);
            if (first != cur) revert BadRoute();
            cur = last;
            _routes[asset].push(legs[i]);
        }
        if (legs.length != 0 && cur != wbnb) revert BadRoute();
        emit RouteSet(asset, legs.length);
    }

    function _v3Ends(bytes calldata path) private pure returns (address first, address last) {
        // token(20) [fee(3) token(20)]+
        if (path.length < 43 || (path.length - 20) % 23 != 0) revert BadRoute();
        first = address(bytes20(path[0:20]));
        last = address(bytes20(path[path.length - 20:]));
    }

    function _v2Ends(bytes calldata path) private pure returns (address first, address last) {
        address[] memory p = abi.decode(path, (address[]));
        if (p.length < 2) revert BadRoute();
        first = p[0];
        last = p[p.length - 1];
    }

    function _send(address asset, address to, uint256 amount) private {
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }
}

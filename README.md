# Loong — memecoin launchpad on BNB Chain

**Launch memes. Go long on real markets.** Loong is a memecoin launchpad on **BNB Smart Chain (chainId 56)**. Every coin
trades on a bonding curve, then graduates into a permanently locked **PancakeSwap Infinity** pool.

- Website: https://loongfamily.app
- X: https://x.com/loongfam
- Integration docs: https://loongfamily.app/#/integrate
- Contracts, roles and risks: https://loongfamily.app/#/contracts
- Deployment manifest: https://loongfamily.app/contracts/manifest.json

## Technology Stack

- **Blockchain**: BNB Smart Chain (BSC)
- **Smart Contracts**: Solidity 0.8.26
- **DEX**: PancakeSwap Infinity (CL pool manager, custom hook) and PancakeSwap Universal Router for BNB routing
- **Frontend**: vanilla JS + ethers.js
- **Development**: Foundry (fork tests against BSC mainnet), OpenZeppelin Contracts 5.x

## Supported Networks

- **BNB Smart Chain Mainnet** (Chain ID: 56) — production
- **BNB Smart Chain Testnet** (Chain ID: 97) — staging, https://testnet.loongfamily.app

## What is different

- **Real-market quote assets.** Pair a coin with BNB, stablecoins, or ~100 tokenized stocks (NVDA, TSLA, AAPL…) and
  selected BNB Chain memecoins — 468 approved quote assets in total.
- **BNB in, BNB out.** Buyers pay with plain BNB and sellers receive plain BNB even when a coin is quoted in another
  asset; the swap through PancakeSwap happens inside the same transaction (`SwapAndBuy`, `LaunchAndBuy.swapLaunchAndBuy`).
- **Free to launch, 1% per trade**: 0.70% to the creator, 0.10% platform, 0.10% buys back and burns that coin,
  0.10% buys back and burns the platform token $LOONG (`LoongBuybackBurner`).
- **Liquidity locked forever** in PancakeSwap Infinity; the locker has no withdrawal function.
- **Every coin address ends in `…9999`**, enforced by the factory.
- A 3-second launch-window fee against snipers; creators can exempt their own wallets.

## BNB Chain mainnet deployment

Deployed 2026-09-25 from block `124024834`. All contracts are source-verified on BscScan.

| Contract | Address |
|---|---|
| LoongLaunchFactory | [0x60dDcE270E1B9A8325daD4A39dB1442598b26B3A](https://bscscan.com/address/0x60dDcE270E1B9A8325daD4A39dB1442598b26B3A) |
| LoongMemeHook (PancakeSwap Infinity hook) | [0xD795A9815D68548aF2Bafc9862f3AdFF3DFb36ec](https://bscscan.com/address/0xD795A9815D68548aF2Bafc9862f3AdFF3DFb36ec) |
| LaunchAndBuy | [0x0198Ae078dEEDDF7c50912C438E681464b568b91](https://bscscan.com/address/0x0198Ae078dEEDDF7c50912C438E681464b568b91) |
| SwapAndBuy | [0x52513D25A55348B69db2bC9De270B59C2793091d](https://bscscan.com/address/0x52513D25A55348B69db2bC9De270B59C2793091d) |
| FeeEscrow | [0x65c6aa6B6974E0Cdd234252EB7645f70934221B7](https://bscscan.com/address/0x65c6aa6B6974E0Cdd234252EB7645f70934221B7) |
| LoongLaunchLocker | [0x65790EBA7B5C1D9B77C1e8e8eCA638Cce812c48C](https://bscscan.com/address/0x65790EBA7B5C1D9B77C1e8e8eCA638Cce812c48C) |
| LoongLaunchDeployer | [0x32F3330Db4153d004C2220216b82fe506D26b72b](https://bscscan.com/address/0x32F3330Db4153d004C2220216b82fe506D26b72b) |
| LoongGraduationExecutor | [0x930469e94c9760830a2Ed7208bf38ff95b342957](https://bscscan.com/address/0x930469e94c9760830a2Ed7208bf38ff95b342957) |
| LoongBuybackVault | [0x9203588B9b347DE8609161846256eC02D5EF6A98](https://bscscan.com/address/0x9203588B9b347DE8609161846256eC02D5EF6A98) |
| LoongFoundationVault ($LOONG vault) | [0xFd89650CCC6f15403996014F6f10382F1f67A485](https://bscscan.com/address/0xFd89650CCC6f15403996014F6f10382F1f67A485) |
| LoongBuybackBurner (UUPS proxy) | [0xEc7e9274b5dD5cC85cF5e35786a6a9FdC2a4c165](https://bscscan.com/address/0xEc7e9274b5dD5cC85cF5e35786a6a9FdC2a4c165) |

BNB Smart Chain Testnet (Chain ID 97): factory `0xc3fF2dd435e1E12e4c59D62D58BAcD4cF64F593F`,
hook `0x670879410F170Eddc00B2596b8c5D6567f502C49`, LaunchAndBuy `0x0262ef2715012DF28AE35927fc4eaf0f47F20CA6`,
SwapAndBuy `0xf5Ca57428D817862814454597fdB16aeD39926CB`.

The full list, the PancakeSwap Infinity dependencies and every approved quote asset are in
[`deployments/56.json`](deployments/56.json) and [`abi-and-manifest/manifest.json`](abi-and-manifest/manifest.json).
Owner roles are held by a Gnosis Safe 2-of-3 multisig.

## Repository layout

```
src/                  Solidity contracts (factory, bonding curve, Infinity hook, routers, vaults, buyback-burner)
test/                 Foundry tests, run against a BNB Smart Chain mainnet fork
script/               Foundry deploy scripts (Deploy.s.sol reads a JSON config)
deployments/56.json   BNB Smart Chain mainnet addresses
abi-and-manifest/     ABIs, errors (with selectors), creation code and the deployment manifest
foundry.toml          solc 0.8.26, optimizer 200 runs, via IR, evm cancun; `bsc` RPC endpoint
```

## Build and test

Requires [Foundry](https://book.getfoundry.sh/). Dependencies: OpenZeppelin Contracts 5.x, PancakeSwap
Infinity core and periphery, Permit2, forge-std (under `lib/`).

```bash
forge build
export BSC_RPC=<a BNB Smart Chain mainnet archive RPC URL>
forge test            # fork tests against BNB Smart Chain mainnet (chainId 56)
```

## Integrate

Wallets, bots, aggregators and launch platforms can list, price, trade and launch Loong coins on-chain with no API key.
Subscribe to `TokenLaunched` on the factory and follow the guide at https://loongfamily.app/#/integrate.

## Licence

Contracts carry their own SPDX identifiers: `GPL-2.0-or-later` (factory, hook, graduation executor, derived from
Pons v2 / genius.fun) and `MIT` (everything else). Original notices are retained as the licences require.

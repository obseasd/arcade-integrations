# Arcade launchpad on Arc: contracts and integration kit

Arcade is a token launchpad and DEX on [Arc](https://arc.network), Circle's
USDC-native L1. Launches live in Uniswap V4 pools attached to a single hook,
`ArcadeHook`. This repository is a read-only mirror of the launchpad's
smart-contract sources, published so that aggregators, explorers, indexers
and trading bots can integrate without guessing.

**There are two hook generations on Arc mainnet.** Generation 1 went live on
2026-08-24 and still serves the ten tokens launched on it. Generation 2 went
live on 2026-09-19 at block 21,568,825 and is the hook of every launch created
from that block on. Both are immutable and both keep working; neither can
migrate a token to the other. If you integrate Arcade you have to handle both,
and [Which generation does a token belong to](#which-generation-does-a-token-belong-to)
below is the two-call answer.

The one change that matters for a router or an aggregator: generation 2 has no
`BEFORE_SWAP_RETURNS_DELTA` / `AFTER_SWAP_RETURNS_DELTA` permission, so its
pools use no custom accounting, need no allowlist entry, and quote correctly
exact-out as well as exact-in. A graduated PUMP pool charges its 1 % as the
pool's own static LP fee instead of a hook-taken delta.

The sources are copied from the Arcade monorepo: generation 1 from commit
`71880148` (2026-09-18) into `v4src/`, generation 2 from commit `ec53c0c6`
(2026-09-19) into `v4src-v2/`. With the compiler settings in `foundry.toml`,
`forge build` reproduces the runtime bytecode deployed on Arc mainnet byte for
byte for both generations: `ArcadeHook`, `ArcadeHookLib`, `ArcadeRwaLib`,
`ArcadeV4Math`, `ArcadeV4SwapRouter`, `LockedVault`,
`ArcadeDividendDistributor`, `ArcadeRwaRegistry`, and, from the standalone
profile, `ArcadeToken`, `ArcadeLpLocker` and `ArcadeBuybackVault` (libraries
linked to the addresses below, immutables filled in). See
[Reproducing the deployed bytecode](#reproducing-the-deployed-bytecode) for the
exact procedure and the result. The hook stack of both generations is also
verified on arc.etherscan.io (exact match); this repository builds the same
bytecode, so the two can be checked against each other.

## Chain

| | |
| --- | --- |
| Network | Arc mainnet |
| Chain id | 5042 |
| Gas token | USDC (native), mirrored as an ERC20 at `0x3600000000000000000000000000000000000000`, 6 decimals |
| Blocks | about every 0.5 s |

USDC on Arc is both the gas token and the ERC20 the contracts below read. There
is no WETH. All amounts in this document are in raw units (USDC has 6 decimals,
launch tokens have 18).

## Contracts

### Shared by both generations

| Contract | Address | Notes |
| --- | --- | --- |
| Uniswap V4 `PoolManager` (canonical) | `0x8366a39cc670b4001a1121b8f6a443a643e40951` | |
| `ArcadeV4SwapRouter` | `0x48A43e71c2AaBBa69193891851B96FE5A51a82C1` | single-hop swap conduit, no fee of its own; works against either hook |
| V4 quoter (`V4Quoter` from v4-periphery) | `0x338F2A7424af45BDD9AcF8E7F56423fbECEecfe6` | |
| V4 state view (`StateView` from v4-periphery) | `0x5d2C332d5De8d35EC9853f92Ab5d8a5e67683D49` | |
| `LockedVault` | `0x6aB6686d53a8f6CA2Fa802D3b559Fe335F2c5b40` | owner of record of every locked LP position, both generations; 3 bytes of code, no functions |
| `ArcadeV4Math` (linked library) | `0x0931aA1082b1ee184f3Fa70B8720500D80C226A2` | identical bytecode in both generations, so it was not redeployed |
| treasury (`TREASURY`) | `0x0B2751fca20728a165d5240178C11D42D4ff552A` | the buyback vault; both hooks send the protocol's cut here |
| twitter escrow | `0xC1D469642A7C1Df9F153A113508Ce512827cb193` | fee destination for handle-attributed launches; the same on both hooks |
| Governance Safe | `0x55589b2eba875a6462f6Cf587058C4d4e317315b` | 2 of 3; owner of both hooks and of the registry |

### Generation 2 (current, every new launch)

| Contract | Address | Notes |
| --- | --- | --- |
| `ArcadeHook` v2 | `0x7706d261f0C370e8f0E273164A603E885C89beC2` | deployed at block 21,568,825; 21,920 bytes; permissions `0x3EC2`; not upgradeable |
| `ArcadeHookLib` (linked library) | `0x4482FCD1531F37c05Ecb5Fc586E5Cbc52E18c248` | linked by the hook; links `ArcadeV4Math` |
| `ArcadeRwaLib` (linked library) | `0x19fD547CeDc3524D320E04E4d6AD2c7466DC5916` | linked by the hook; links `ArcadeHookLib` |
| `ArcadeRwaRegistry` | `0xa012614F015EEEC7fccBA6575FC4753ee7Ef70E6` | the RWA quote policy; owner is the Safe |
| `ArcadeDividendDistributor` (gen 2) | `0xF1874BEf547f4DDD546D2C5419Ac070783AbEe01` | `hook()` returns the v2 hook |

### Generation 1 (the ten tokens launched before 2026-09-19)

| Contract | Address | Notes |
| --- | --- | --- |
| `ArcadeHook` v1 | `0x695cfF9C7F11fa87ca05c7b0A0fa64C3554B3eCe` | deployed at block 20,030,281; 24,153 bytes; permissions `0x3ECE`; not upgradeable |
| `ArcadeHookLib` (linked library) | `0x4F0ad6705bBC3D907D3580eDde1920c1A83C08aD` | |
| `ArcadeRwaLib` (linked library) | `0xCF541Aa04283bCfF85eEA0a32C018b8Ae6Dc050A` | |
| `ArcadeDividendDistributor` (gen 1) | `0x3423f4C418cd811fb77E4C4940E8C1fCc87B062C` | stays bound to the v1 hook |

The v1 hook is not paused, not deprecated and not migratable. It keeps its
tokens, its fee schedule and its curve. New launches simply no longer land on
it.

### Not part of the hook stack

| Contract | Address | Notes |
| --- | --- | --- |
| `SwapFeeRouter` | `0x8090435Df4EeC29178bE5373677aCA8dE54f58bD` | the site's router for tokens that are not Arcade launches; 0.5 % on those only; not needed to trade launchpad pools; source not in this mirror |
| ARCADE platform token (`ArcadeToken`) | `0xcaaD9713114A3c26131594E7e3a908f41e7d4549` | fixed supply, no owner |
| USDC/ARCADE pool (canonical Uniswap V3, 1 %) | `0x11b73810472525A13c90bee4f1a6edCB039Aee78` | |
| `ArcadeLpLocker` | `0xA39432d3e069Cd8Bc7A5d78628464edFC40A5E69` | holds the platform token's V3 position forever |
| `ArcadeBuybackVault` | `0x0B2751fca20728a165d5240178C11D42D4ff552A` | both hooks' `TREASURY`; receives protocol fees and buys ARCADE |

The same addresses are in [`deployments/mainnet.json`](deployments/mainnet.json),
where the `launchpad.generations` array carries one entry per hook.

### The hook address encodes its permissions

Uniswap V4 reads a hook's permissions from the low 14 bits of its address.

`0x7706d261f0C370e8f0E273164A603E885C89beC2` ends in `0x3EC2` = 16066 =

`BEFORE_INITIALIZE | AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | AFTER_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP | AFTER_ADD_LIQUIDITY_RETURNS_DELTA`

`0x695cfF9C7F11fa87ca05c7b0A0fa64C3554B3eCe` ends in `0x3ECE` = 16078 = the
same eight bits plus `BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA`.

Neither has `beforeDonate` / `afterDonate` (they revert `HookNotImplemented`)
and neither has `afterRemoveLiquidity` logic.

Those two extra bits on v1 are the whole reason v2 exists. They are what
Uniswap's public router filter calls custom accounting: a hook that carries
either one needs a manual allowlist entry before any of its pools is routed, and
a freshly deployed hook address starts unrouted. v1 carried them for exactly one
purpose, taking the graduated PUMP fee out of the swap as a delta. v2 charges
that fee as the pool's native LP fee instead, the bits go, and any V4 router can
trade a v2 pool the day it graduates with no integration on our side.

## Which generation does a token belong to

`registeredLaunches(address)` returns true on the hook that owns the token and
false on the other. Ask the newest hook first, since that is where every new
launch is:

```solidity
bool v2 = IArcadeHook(0x7706d261f0C370e8f0E273164A603E885C89beC2).registeredLaunches(token);
bool v1 = !v2 && IArcadeHook(0x695cfF9C7F11fa87ca05c7b0A0fa64C3554B3eCe).registeredLaunches(token);
```

A token is on at most one hook. Every per-token getter (`poolIdOf`,
`quoteAssetOf`, `poolFeeOf`, `getCurveState`, `currentFeeBps`, ...) returns zero
values on the wrong hook rather than reverting, so a wrong guess is silent: read
`registeredLaunches` first, do not infer the generation from a zero.

Two shortcuts, if you would rather not make two calls:

- By block. A token created at or after block 21,568,825 is on v2, before it is
  on v1. The `TokenLaunched` / `LaunchCreated` event you indexed carries the
  hook address as its emitter, which is the direct answer.
- By the `PoolKey` you already hold. `key.hooks` is the hook.

## What differs between the generations

| | Generation 1 `0x695cfF9C` | Generation 2 `0x7706d261` |
| --- | --- | --- |
| Permission bitmap | `0x3ECE`, includes both swap-delta bits | `0x3EC2`, no swap-delta bits |
| Routable by an arbitrary V4 router | needs an allowlist entry | yes, by default |
| Exact-out quotes | unreliable on PUMP (the hook took a delta on the specified side) | correct in every mode |
| Graduated PUMP pool fee | `poolFeeOf` = 0; the hook takes 1 % declining to 0.30 % in USDC as a swap delta | `poolFeeOf` = 10000 (1 %), static native LP fee, from creation |
| PUMP fee oracle | `feeObs(poolId)` returns the price EMA | does not exist: calling `feeObs` on the v2 hook reverts |
| Per-swap treasury event | `SwapTreasuryFee(poolId, treasuryUsdc)` | does not exist: the treasury cut arrives with the harvest, in `RoyaltyPaid` |
| `currentFeeBps(token)` | PUMP: the live decayed rate; CLANKER: the tier | `poolFeeOf(token) / 100` in every mode, so PUMP is always 100 |
| Harvesting a graduated PUMP pool | nothing to harvest, the hook took the fee per swap | `collectFees(token)`, the same call CLANKER uses, 80/20 creator/treasury |
| Post-graduation anti-sniper skim | taken on swaps alongside the fee | gone with the swap take; the anti-sniper tax is curve-only (see below) |
| RWA quote policy | `setRwaQuoteAllowed(asset, bool)` on the hook, start cap a `createRwaLaunch` argument with 6-decimal bounds | `ArcadeRwaRegistry`, per asset, start cap fixed in the asset's own raw units |
| RWA live on mainnet | no, no quote was ever allowed | yes, XAUM |
| Dividend distributor | `0x3423f4C4` | `0xF1874BEf` |

Unchanged between the generations: the curve (`ArcadeV4Curve` is byte-identical
in both, same virtual reserves, same `CURVE_SUPPLY`, same 1 % curve trade fee
split 50/50 creator/treasury), `CREATION_FEE` = 3 USDC, the 1 % migration fee,
the 80/20 creator/treasury split on harvested fees, the CLANKER 1/2/3 % tiers,
the first-five-minutes buy cap, the graveyard sweep, `tickSpacing` 200, and the
whole discovery surface.

## Repository layout and build

```
v4src/                     the hook stack, GENERATION 1, builds 0x695cfF9C
v4src-v2/                  the hook stack, GENERATION 2, builds 0x7706d261 (current)
                           both directories have the same shape:
  ArcadeHook.sol           the hook: launches, bonding curve, graduation, fees
  libraries/               ArcadeHookLib, ArcadeRwaLib, ArcadeV4Math (linked), ArcadeV4Curve (internal math)
  interfaces/              IArcadeDividendDistributor, ILaunchpadSnipe, IArcadeRwaRegistry (v2 only)
  ArcadeRwaRegistry.sol    the RWA quote policy (v2 only)
  ArcadeV4SwapRouter.sol   swap conduit
  LockedVault.sol          owner of record of locked positions
  ArcadeDividendDistributor.sol, CreatorSplitter.sol, HolderAirdropDistributor.sol
v4test/                    the generation 1 hook test suite
src/launchpad/             ArcadeLaunchToken (the ERC20 every launch mints), ArcadeRwaLaunchToken, ArcadeTwitterEscrowV4
src/token/ArcadeToken.sol  the platform token
src/treasury/              ArcadeLpLocker, ArcadeBuybackVault
src/cctp/                  ArcadeCctpBuyReceiver (bridge and buy through CCTP V2)
deployments/mainnet.json   addresses
```

`v4src-v2/` is a full copy, not a patch: the seven files the two generations
share (`ArcadeV4SwapRouter`, `LockedVault`, `CreatorSplitter`,
`HolderAirdropDistributor`, `ArcadeV4Curve`, `ArcadeV4Math`, `ILaunchpadSnipe`)
are byte-identical in both directories, and `diff -r v4src v4src-v2` is a
readable summary of the upgrade. Both directories import the launch tokens from
the shared `src/launchpad/`.

```sh
git clone --recursive https://github.com/obseasd/arcade-integrations
cd arcade-integrations
FOUNDRY_PROFILE=v2 forge build           # generation 2, the current hook stack
FOUNDRY_PROFILE=v2 forge build --sizes   # ArcadeHook: 21,920 bytes runtime
forge build                              # generation 1
forge build --sizes                      # ArcadeHook: 24,153 bytes runtime
forge test                               # generation 1 test suite, 273 tests
FOUNDRY_PROFILE=standalone forge build   # platform token, locker, vault, CCTP receiver
```

The two generations need two profiles and two artifact directories (`out/` and
`out-v2/`) because they share contract names and foundry keys artifacts by file
name. The compiler settings are identical in both, and they are the deployment
settings: they must not be changed if you want matching bytecode. The hook stack
uses solc 0.8.26, `via_ir`, 200 optimizer runs, `evm_version = cancun`, no
metadata trailer; the standalone profile uses solc 0.8.35, `via_ir`, 1 optimizer
run, no metadata trailer. Dependencies are git submodules pinned to the commits
the monorepo builds against: forge-std v1.16.1, OpenZeppelin v5.6.1, v4-core
`46c68346`, v4-periphery `363226d9`.

The `v4test/` suite covers generation 1 and is kept as it was. The generation 2
suite is not mirrored here; its adversarial cases are described in the source
comments of `v4src-v2/`, each tagged with the audit and finding it closes.

### Reproducing the deployed bytecode

The claim this repository makes is that its `forge build` output equals the code
on chain. To check it yourself:

1. Build the generation you want (`FOUNDRY_PROFILE=v2 forge build` for v2,
   `forge build` for v1).
2. Take `deployedBytecode.object` from the artifact, for example
   `out-v2/ArcadeHook.sol/ArcadeHook.json`.
3. Replace each `__$...$__` placeholder listed in
   `deployedBytecode.linkReferences` with the deployed address of that library,
   from the tables above. For the v2 hook that is `ArcadeHookLib` at seven
   offsets and `ArcadeRwaLib` at two; for `ArcadeHookLib` it is `ArcadeV4Math`
   at five; for `ArcadeRwaLib` it is `ArcadeHookLib` at one.
4. Compare against `cast code <address> --rpc-url https://rpc.mainnet.arc.io`.
   The only bytes that differ are the constructor-set immutables, whose offsets
   are in `deployedBytecode.immutableReferences`. Read the on-chain value at
   each of those offsets and check it against what the constructor was given.

Run on 2026-09-20 against `https://rpc.mainnet.arc.io`, every contract matched:

| Contract | Runtime bytes | Result |
| --- | --- | --- |
| `ArcadeHook` v2 | 21,920 | identical after linking; 36 immutable slots, all holding the PoolManager, USDC or `LockedVault` |
| `ArcadeHookLib` v2 | 16,289 | identical after linking; 1 immutable slot, its own address |
| `ArcadeRwaLib` v2 | 9,070 | identical after linking; 1 immutable slot, its own address |
| `ArcadeV4Math` | 3,204 | identical, no linking and no immutables |
| `ArcadeRwaRegistry` | 1,962 | identical, no linking and no immutables |
| `ArcadeDividendDistributor` gen 2 | 7,599 | identical; 4 immutable slots, all holding the v2 hook address |
| `ArcadeV4SwapRouter` | 3,157 | identical; 4 immutable slots, all holding the PoolManager |
| `ArcadeHook` v1 | 24,153 | identical after linking; immutables only |
| `ArcadeHookLib` v1 | 16,424 | identical after linking; immutables only |
| `ArcadeRwaLib` v1 | 9,113 | identical after linking; immutables only |
| `ArcadeDividendDistributor` gen 1 | 7,483 | identical; 4 immutable slots, all holding the v1 hook address |
| `LockedVault` | 3 | identical |

`ArcadeV4Math` builds to the same 3,204 bytes from both directories and matches
the one deployed copy, which is why both generations link the same address.

## Discovery: finding every launch

Everything starts at the hook, and there are two of them. Index both, from their
own deploy blocks: 20,030,281 for v1 and 21,568,825 for v2.

- `tokensCount()` and `allTokens(i)` enumerate every launch token created on
  that hook, in creation order. At the time of writing v1 has 10 and v2 has
  none yet, which is exactly the trap: a v2 integration that only checks
  `tokensCount()` sees an empty launchpad and is still correct.
- `event TokenLaunched(address indexed token, address indexed creator, uint8 mode, string name, string symbol, string metadataURI)`
- `event LaunchCreated(PoolId indexed poolId, address indexed token, address creator, uint8 mode)`

Both events are declared in `ArcadeHook` and again in `ArcadeHookLib`; the
library runs by `delegatecall`, so on chain they are always emitted by the hook
address. That emitter is the generation.

Per-token state, on the hook that owns the token:

| Getter | Meaning |
| --- | --- |
| `registeredLaunches(token)` | true for every Arcade launch on this hook |
| `poolIdOf(token)` | the V4 `PoolId` |
| `quoteAssetOf(token)` | the quote currency; the zero address means USDC |
| `poolFeeOf(token)` | the pool's static LP fee (`fee` in the `PoolKey`) |
| `getCurveState(poolId)` | `mode`, `status`, `realUsdcReserve`, `tokensSold`, `creator` |
| `getFeeOwner(poolId)` | `creator`, `creator2`, `creator2Bps`, `feeTierBps`, `twitterEscrow`, `slotIndex` |
| `currentFeeBps(token)` | the pool's trading fee in bps once graduated, 0 before (see the differences table: v2 always returns `poolFeeOf / 100`) |
| `currentSnipeBps(token)` | the live anti-sniper tax on curve buys (bps), 0 when none |
| `clankerPos(token)` | `tickLower`, `tickUpper`, `seeded`, `launchedAt`. On v2 this is also set for a graduated PUMP pool (the full-range graduation seed), not only for CLANKER |
| `lastTradeAt(poolId)` | timestamp of the last swap on a graduated pool |
| `graveyardSwept(poolId)` | true once the pool has been swept; both generations |
| `isHarvestable(token)` | **v2 only**: seeded and graduated and not swept, the one cue a harvest bot needs |

`mode` is `0` PUMP, `1` CLANKER, `3` RWA (`2`, CLANKER_V3, is rejected by
`createLaunch` and never existed on mainnet). `status` is `0` Curving,
`1` GraduationStarted, `2` Graduated.

## Building a launch's PoolKey

```solidity
address hook = /* the generation that returns true for registeredLaunches(token) */;
address quote = IArcadeHook(hook).quoteAssetOf(token);
if (quote == address(0)) quote = 0x3600000000000000000000000000000000000000; // USDC
(address c0, address c1) = quote < token ? (quote, token) : (token, quote);
PoolKey({
    currency0:   Currency.wrap(c0),
    currency1:   Currency.wrap(c1),
    fee:         IArcadeHook(hook).poolFeeOf(token),
    tickSpacing: 200,
    hooks:       IHooks(hook)
});
```

`hookData` is empty. Neither hook cares who the swap sender is: any V4 router
(`ArcadeV4SwapRouter`, the canonical Universal Router, your own `unlock`
callback) can trade a graduated pool.

Read `poolFeeOf(token)`, never assume it. On v2 a PUMP pool's fee is 10000 from
the moment `createLaunch` returns, before graduation as well as after, because
the fee is baked into the `PoolKey` at creation. **A `PoolKey` built with fee 0
for a v2 PUMP token hashes to a different `PoolId` and you will be reading an
empty pool**, with no revert to tell you. On v1 a PUMP pool's fee really is 0
and CLANKER's is its tier.

Do not assume the quote is USDC either. Since 2026-09-17 the protocol default
quote for CLANKER launches is the ARCADE token (`clankerQuote()` returns
`0xcaaD9713114A3c26131594E7e3a908f41e7d4549` and `clankerQuoteIsDefault()`
is true); a creator can still force USDC, and an RWA launch is quoted in its
real-world asset. An ARCADE-quoted pool has an 18-decimal quote and its
`startMcap` bounds are expressed in ARCADE. Always read `quoteAssetOf(token)`
and the quote's `decimals()`.

## Launch modes

### PUMP (mode 0): bonding curve, then a V4 pool

1. `createLaunch` deploys an `ArcadeLaunchToken` (1,000,000,000 tokens, 18
   decimals, all minted to the hook) and initialises the V4 pool with the hook,
   after pulling the flat creation fee (`CREATION_FEE` = 3 USDC) to the
   treasury. The creator may buy atomically in the same transaction
   (`creatorBuyUsdc`), capped at 10 % of the supply (`DevBuyExceedsCap`).
2. While `status == 0` the token trades **on the hook, not in the pool**:
   `buy(token, usdcIn, minTokensOut)` and `sell(token, tokensIn, minUsdcOut)`.
   Any V4 swap on the pool reverts `LiquidityNotPermitted`. The curve is
   constant-product with virtual reserves (`ArcadeV4Curve`, identical in both
   generations): `VIRTUAL_USDC_RESERVE` 5,500 USDC, `VIRTUAL_TOKEN_RESERVE`
   1,094,200,000 tokens, `CURVE_SUPPLY` 777,000,000 tokens sold on the curve, a
   1 % fee on every curve trade (`TRADE_FEE_BPS`, split 50/50
   creator/treasury). Quote with
   `ArcadeV4Curve.simulateBuy(tokensSold, realUsdcReserve, grossUsdcIn)` and
   `simulateSell(tokensSold, realUsdcReserve, tokensIn)`; the inputs come from
   `getCurveState`. Events: `CurveBuy(poolId, buyer, grossUsdcIn, tokensOut)`,
   `CurveSell(poolId, seller, tokensIn, usdcOut)`.
3. When the curve sells out (`realUsdcReserve` reaches about 13,473 USDC,
   `GRADUATION_USDC`) the buy that crosses the line graduates the token in the
   same transaction: a 1 % migration fee of the raise goes to the treasury
   (`MIGRATION_FEE_BPS`), the remaining 223,000,000 tokens plus the USDC seed a
   locked V4 position, and `Graduated(poolId, finalUsdcReserve, tokensInLP)` is
   emitted. `status` is `1` only inside that transaction.
4. After graduation the pool trades like any V4 pool, and here the generations
   part:
   - **v2**: the pool has a static LP fee of 1 % (`poolFeeOf` = 10000, set at
     creation) and **the hook takes nothing on a swap**. The fee accrues in the
     locked position, in whichever currency the trade paid it. Anyone can call
     `collectFees(token)` to harvest it, split 80 % creator / 20 % treasury
     (`POST_GRAD_CREATOR_BPS`), `RoyaltyPaid(poolId, creator, creatorAmount, treasuryAmount, currency)`
     per currency. This is exactly the CLANKER path.
   - **v1**: `poolFeeOf` = 0 and **the hook takes its fee in USDC on every
     swap**: `currentFeeBps(token)` of the USDC side, charged in `beforeSwap`
     when USDC is the specified currency and in `afterSwap` otherwise. The fee
     is 1 % at graduation (`PUMP_FEE_MAX_BPS`) and decays linearly in log market
     cap to a 0.30 % floor (`PUMP_FEE_MIN_BPS`) once the pool's price EMA sits
     23,026 ticks (10x) above the graduation tick. The EMA has a one-hour time
     constant and is updated at most once per block, after the fee is taken, so
     a swap never moves the fee it pays. The take is split 80 / 20 and
     `SwapTreasuryFee(poolId, treasuryUsdc)` repeats the treasury part for
     indexers. A v1 PUMP pool has nothing to harvest.
5. A creator can arm an anti-sniper tax at launch (`snipeStartBps` up to 50 %,
   decaying linearly to 0 over at most 3,600 s). On both generations it applies
   to **curve buys**, taken in tokens out of the hook's inventory and split
   80 / 20 creator / treasury (`AntiSnipeApplied`). v1 additionally skimmed it
   on post-graduation swaps, alongside the hook fee and capped with it at 60 %
   (`MAX_TOTAL_TAKE_BPS`); v2 takes nothing on a swap, so that skim is gone.
   Read `currentSnipeBps(token)` before quoting a curve buy.

### CLANKER (mode 1): direct single-sided locked liquidity

Identical in both generations. `createLaunch` with mode 1 mints the same
1,000,000,000-token ERC20, seeds a single-sided position of the whole supply
above the starting market cap (`startMcapUsdc`, default 35,000 USDC, bounds
1,000 to 10,000,000 USDC; in the quote's own units and the owner-set bounds when
the quote is not USDC) and locks it. The launch is `Graduated` from its first
block and trades in the V4 pool immediately. The creator chooses the fee tier at
launch: `feeTier` 1, 2 or 3, stored as the pool's **native LP fee** `poolFeeOf`
= 10000 / 20000 / 30000. **The hook takes nothing on CLANKER swaps**;
`currentFeeBps(token)` returns the tier. Anyone can call `collectFees(token)` to
harvest the locked position's accrued LP fees; they are split 80 / 20 creator /
treasury in each currency (`RoyaltyPaid` for both).

### RWA (mode 3): live on generation 2

`createRwaLaunch` pairs a launch with an allowed real-world-asset quote and
routes a creator-set trade tax (1 to 3 %, the pool's native LP fee) to holders
through `ArcadeDividendDistributor`.

On **v1** no quote was ever allowed, so `createRwaLaunch` reverts
`QuoteNotAllowed` there and no v1 RWA pool exists or can exist.

On **v2** the policy moved out of the hook into `ArcadeRwaRegistry`
`0xa012614F015EEEC7fccBA6575FC4753ee7Ef70E6`, owned by the Safe. Per asset it
holds: `allowed`, `decimals` (read from the token itself, bounded 2 to 27), a
**fixed** start market cap in the asset's raw units, a price source (a canonical
V3 pool that prices the asset in USDC, or the zero address meaning 1 USD), and a
`permissioned` flag. The start cap is no longer a `createRwaLaunch` argument:
the hook reads `startMcapOf(quote)` and every launch on that asset opens at the
same cap. This is why v2's `createRwaLaunch` has one parameter fewer than v1's.

| Getter | Meaning |
| --- | --- |
| `quotes(address)` | the full record: `allowed`, `decimals`, `startMcap`, `priceSource`, `permissioned` |
| `startMcapOf(address)` | the fixed start market cap in the asset's raw units |
| `isAllowed(address)` | shorthand |
| `quoteList()` | every asset ever set, so you can enumerate without log scraping |

`event QuoteSet(address indexed asset, bool allowed, uint8 decimals, uint128 startMcap, address priceSource, bool permissioned)`.

At the time of writing the list is one asset: XAUM
`0x178b01f61CBeA1D2a5581Fe1621Be607835EC349`, 18 decimals, start cap
`7854505000000000000` (7.854505 XAUM, about 35,000 USD at the canonical
XAUM/USDC pool `0x5E82892d361A6C680027A97da2280064B8FC8A52`), `permissioned`
false. An XAUM-quoted pool is an 18-decimal quote: read `decimals()`.

`harvestRwaFees(token)` splits the harvested tax between holders (through the
distributor), the creator and the treasury. `isHarvestable(token)` is the cue.
The hook's `rwaRegistry()` is set once and cannot be repointed, and the
registry's own `renounceOwnership()` is overridden to revert, so the asset list
always has someone who can pause an asset.

## Trading a graduated pool

`ArcadeV4SwapRouter` is a stateless, ownerless single-hop router and works
against both generations:

```solidity
// approve the router for the input currency first
router.exactInputSingle(key, zeroForOne, amountIn, minAmountOut, recipient, 0 /* sqrtPriceLimitX96: 0 = no limit */);
router.exactOutputSingle(key, zeroForOne, amountOut, maxAmountIn, recipient, 0);
```

It emits `SwapExecuted(payer, recipient, inputCurrency, outputCurrency, amountIn, amountOut, zeroForOne)`
with the realised amounts and reverts `SlippageExceeded(actual, limit)` or
`IncompleteOutput(delivered, requested)`. The V4 quoter at
`0x338F2A7424af45BDD9AcF8E7F56423fbECEecfe6` simulates the full swap.

On v2 the quoter's answer is the whole story, exact-in and exact-out alike,
because the hook returns no delta and the fee is the pool's own. On v1 an
exact-out quote on a graduated PUMP pool is unreliable: the hook takes its cut
as a delta on the specified side, which is what the missing permission bits were
for. If you support v1 pools, quote them exact-in.

## Limits and reverts to expect

| Situation | Revert |
| --- | --- |
| V4 swap on a PUMP token still on its curve | `LiquidityNotPermitted` |
| V4 swap during the graduation transaction | `GraduationInProgress` |
| `buy` / `sell` on a graduated (or CLANKER) token | `LiquidityNotPermitted` |
| `buy` / `sell` output below the caller's minimum | `Slippage` |
| CLANKER or RWA buy too large in the first five minutes | `BuyExceedsCap` |
| adding liquidity from anything but the hook | `LiquidityNotPermitted` |
| removing a locked position | `LockedPosition` |
| `collectFees` / `harvestRwaFees` on a swept pool | `AlreadySwept` (v2 says so directly; v1 dies inside the PoolManager) |
| `graveyardSweep` on an already swept pool | `AlreadySwept` |
| `setDividendDistributor` with a distributor not bound to this hook | `DistributorHookMismatch` (v2 only) |
| `createRwaLaunch` with an asset the registry does not allow | `QuoteNotAllowed` |

The first-window buy cap: for 300 s after launch (`clankerPos(token).launchedAt`)
a single swap may deliver at most 1 % of the supply in the first minute, 2 % in
the second, up to 5 % in the fifth; after that there is no cap. The schedule is
fixed in code; the owner can only switch it off globally (`setClankerBuyCap`
with `maxBuyBps` = 0; it is on at the time of writing). The cap is checked in
`afterSwap`, so quotes are unaffected but the swap reverts.

There is no external liquidity on either generation: `beforeAddLiquidity`
accepts only the hook itself, and every position the hook seeds is locked
(`positions(key).locked`) with its ERC-6909 receipt owned by `LockedVault`,
which has no code path to move it. The one exception is `graveyardSweep(token)`:
a graduated pool with no swap for `graveyardPeriod()` (365 days, owner-adjustable
but never below 180 days) can be swept once, by anyone, which pulls the residual
liquidity to the treasury and emits `GraveyardSwept`. A traded pool can never be
swept. On v2 the fee accrued up to the sweep is still split 80 / 20 with the
creator first; only the principal goes to the treasury.

`clankerPos(token).seeded` stays true after a sweep, because it records the tick
range rather than the liquidity. Do not use it as a harvest cue on its own: on
v2 use `isHarvestable(token)`, on v1 combine `seeded` with
`!graveyardSwept(poolIdOf(token))`.

### Pending credits (v2)

When a fee payout cannot reach its recipient (a contract that rejects the
transfer, a token that blocks it), the hook credits it instead of reverting, and
the recipient pulls it later with `claimPendingToken(token)`. On v2 anyone can
push such a credit to whoever owns it with
`claimPendingTokenFor(address token, address recipient)`. It pays `recipient`,
never the caller, and the amount and destination are fixed by the credit, so the
caller chooses only the moment. It exists because the usual owners of a stranded
credit (the buyback vault, the Twitter escrow) are contracts with no way to call
the hook themselves. Neither claim is blocked by `pause()`.

## What the owner can and cannot do

Both hooks are `Ownable2Step` and both are owned by the 2-of-3 Safe. `owner()`
is `0x55589b2eba875a6462f6Cf587058C4d4e317315b`, `pendingOwner()` is zero on
both.

Setters that exist, all `onlyOwner`:

| Setter | Effect |
| --- | --- |
| `pause()` / `unpause()` | blocks `createLaunch`, `createRwaLaunch`, `buy`, `sell`, `collectFees`, `harvestRwaFees`. **Does not block V4 swaps**: `beforeSwap` and `afterSwap` are not pausable, a graduated pool keeps trading while paused, and the pending-credit claims stay open |
| `setTreasury(address)` | where the protocol's fee share goes from then on |
| `setTwitterEscrow(address)` / `setTokenForwarder(address)` | fee destinations for handle-attributed launches (future launches) |
| `setDividendDistributor(address)` | one-time (`AlreadySet` afterwards). On v2 the candidate must already be bound to this hook or the call reverts `DistributorHookMismatch`, so the slot cannot be burned on the wrong distributor |
| `setClankerQuote(quote, defaultMcap, minMcap, maxMcap, makeDefault)` / `setClankerQuoteIsDefault(bool)` | the optional non-USDC quote and start-cap bounds for **future** CLANKER launches; an existing pool's quote is stored per token and never changes |
| `setRwaRegistry(address)` | **v2 only**, one-time. v1 has `setRwaQuoteAllowed(asset, bool)` instead |
| `setRwaGraveyardSink(address)` | one-time |
| `setClankerBuyCap(maxBuyBps, windowSecs)` | the global on/off switch of the first-five-minutes cap. Only `maxBuyBps == 0` is read; the ramp itself is fixed in code |
| `setGraveyardPeriod(uint40)` | never below 180 days (`GraveyardPeriodTooShort`) |

On the registry, the Safe can add an asset, re-price its start cap, set its
price source or switch it off (`QuoteSet`). That changes **future** launches
only: a launch's parameters are read once, at creation.

What no owner action can do, on either generation: change the fee of an existing
pool (a CLANKER tier and a v2 PUMP fee are stored per launch, the v1 PUMP
schedule is compiled constants), take a different cut than 80 / 20, block, pause
or censor swaps on a graduated pool, withdraw or move a locked position, mint
tokens, migrate a token from one hook to the other, or upgrade either hook. The
constants (`CREATION_FEE`, curve parameters, fee bounds, cap schedule) are
compiled in and the address is tied to this bytecode.

## Audits

Generation 2 went through two independent adversarial reviews before it was
deployed, on 2026-09-18 and 2026-09-19. Neither found a critical or high issue.
Every finding and the change that closed it is in the source comments of
`v4src-v2/`, tagged with the date and the finding id, so you can read the reason
next to the code: `MEDIUM-1` (treasury rotation in the distributor), `LOW-1`
(the holders leg of an RWA harvest is pull-safe), `LOW-3` (`isHarvestable` and
the `AlreadySwept` cue), `M1` (`claimPendingTokenFor`) and `L2`
(`DistributorHookMismatch`).

## Reference implementation

KyberSwap's aggregator integrates both trading paths; the pull requests are a
complete, reviewed reference for a quoting engine:

- [kyberswap-dex-lib #1674](https://github.com/KyberNetwork/kyberswap-dex-lib/pull/1674):
  the V4 hook, generation 1 (graduated PUMP pools with the USDC-side hook fee,
  CLANKER pools with the native fee, the buy cap).
- [kyberswap-dex-lib #1675](https://github.com/KyberNetwork/kyberswap-dex-lib/pull/1675):
  the PUMP bonding curve as a liquidity source (curve math, fees, anti-sniper).
- [kyberswap-dex-lib #1697](https://github.com/KyberNetwork/kyberswap-dex-lib/pull/1697):
  generation 2, where a graduated PUMP pool is an ordinary static-fee V4 pool.

## Data

Public subgraph (Goldsky), mainnet. It indexes **both** generations, so a `Token`
is there whichever hook launched it:

```
https://api.goldsky.com/api/public/project_cmrntot4nn29m01stbb661x1d/subgraphs/arcade-charts-mainnet/prod/gn
```

Entities:

- `Token`: `id creator mode poolFee createdAt migrated migratedAt migratedPair name symbol metadataURI totalVolumeUsdc tradeCount feesUsdc lastPriceUsdc usdcLiquidity holderCount`
- `Trade`: `id token trader source pool price volumeUsdc isBuy blockTime blockNumber logIndex protocolFeeUsdc`
- `V4Pool`: `id token creator mode tokensSold hook quoteReserve tokenReserve tvlUsdc liquidity sqrtLowerX96 sqrtUpperX96 quote quoteDecimals`
- `TokenHourData`: `id token hour volumeUsdc open high low close tradeCount`

`V4Pool.hook` is the generation. `Token.poolFee` is `poolFeeOf`, so a v2 PUMP
token reads 10000 and a v1 PUMP token reads 0.

```graphql
{
  tokens(first: 20, orderBy: createdAt, orderDirection: desc) {
    id name symbol mode poolFee migrated lastPriceUsdc usdcLiquidity
  }
}
```

The site publishes a machine-readable manifest of the live addresses, updated
with every deployment: <https://www.arcade.trading/deployments.json>.

## Changelog

- **2026-09-20**: generation 2 added. `v4src-v2/` holds the sources of the hook
  live since 2026-09-19 (`0x7706d261`), with the new `ArcadeRwaRegistry` and the
  generation-2 dividend distributor; `foundry.toml` gained a `v2` profile;
  `deployments/mainnet.json` gained a `launchpad.generations` array and the
  registry's quote list. Generation 1 stays exactly where it was in `v4src/`.
  The whole of the two stacks was rebuilt and compared against mainnet on this
  date; see [Reproducing the deployed bytecode](#reproducing-the-deployed-bytecode).
- **2026-09-18**: first publication. Generation 1 sources (`0x695cfF9C`,
  monorepo commit `71880148`), the addresses, the discovery and quoting notes,
  and the Kyber reference pull requests.

## Licence

MIT for the Arcade sources (see `LICENSE`). Uniswap v4-core and v4-periphery
are pulled in as submodules under their own licences.

# Arcade launchpad on Arc: contracts and integration kit

Arcade is a token launchpad and DEX on [Arc](https://arc.network), Circle's
USDC-native L1. Launches live in Uniswap V4 pools attached to a single hook,
`ArcadeHook`. This repository is a read-only mirror of the launchpad's
smart-contract sources, published so that aggregators, explorers, indexers
and trading bots can integrate without guessing.

The sources are copied from the Arcade monorepo at commit `71880148`
(2026-09-18). With the compiler settings in `foundry.toml`, `forge build`
reproduces the runtime bytecode deployed on Arc mainnet byte for byte for
`ArcadeHook`, `ArcadeHookLib`, `ArcadeRwaLib`, `ArcadeV4Math`,
`ArcadeV4SwapRouter`, `LockedVault`, `ArcadeDividendDistributor`,
`ArcadeToken`, `ArcadeLpLocker` and `ArcadeBuybackVault` (libraries linked to
the addresses below, immutables filled in). The hook is not verified on a
block explorer yet; this repository is the way to check it.

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

| Contract | Address | Notes |
| --- | --- | --- |
| Uniswap V4 `PoolManager` (canonical) | `0x8366a39cc670b4001a1121b8f6a443a643e40951` | |
| `ArcadeHook` | `0x695cfF9C7F11fa87ca05c7b0A0fa64C3554B3eCe` | deployed at block 20,030,281; 24,153 bytes; not upgradeable; owner is the 2-of-3 Safe `0x55589b2eba875a6462f6Cf587058C4d4e317315b` |
| `ArcadeHookLib` (linked library) | `0x4F0ad6705bBC3D907D3580eDde1920c1A83C08aD` | linked by the hook; links `ArcadeV4Math` |
| `ArcadeRwaLib` (linked library) | `0xCF541Aa04283bCfF85eEA0a32C018b8Ae6Dc050A` | linked by the hook; links `ArcadeHookLib` |
| `ArcadeV4Math` (linked library) | `0x0931aA1082b1ee184f3Fa70B8720500D80C226A2` | linked by `ArcadeHookLib` |
| `ArcadeV4SwapRouter` | `0x48A43e71c2AaBBa69193891851B96FE5A51a82C1` | single-hop swap conduit for the hook's pools, no fee of its own |
| V4 quoter (`V4Quoter` from v4-periphery) | `0x338F2A7424af45BDD9AcF8E7F56423fbECEecfe6` | |
| V4 state view (`StateView` from v4-periphery) | `0x5d2C332d5De8d35EC9853f92Ab5d8a5e67683D49` | |
| `LockedVault` | `0x6aB6686d53a8f6CA2Fa802D3b559Fe335F2c5b40` | owner of record of every locked LP position; 3 bytes of code, no functions |
| `SwapFeeRouter` | `0x8090435Df4EeC29178bE5373677aCA8dE54f58bD` | the site's router for tokens that are not Arcade launches; 0.5 % on those only; not needed to trade launchpad pools; source not in this mirror |
| `ArcadeDividendDistributor` | `0x3423f4C418cd811fb77E4C4940E8C1fCc87B062C` | RWA mode dividends; bound to the hook |
| ARCADE platform token (`ArcadeToken`) | `0xcaaD9713114A3c26131594E7e3a908f41e7d4549` | fixed supply, no owner |
| USDC/ARCADE pool (canonical Uniswap V3, 1 %) | `0x11b73810472525A13c90bee4f1a6edCB039Aee78` | |
| `ArcadeLpLocker` | `0xA39432d3e069Cd8Bc7A5d78628464edFC40A5E69` | holds the platform token's V3 position forever |
| `ArcadeBuybackVault` | `0x0B2751fca20728a165d5240178C11D42D4ff552A` | the hook's `TREASURY`; receives protocol fees and buys ARCADE |

The same addresses are in [`deployments/mainnet.json`](deployments/mainnet.json).

### The hook address encodes its permissions

Uniswap V4 reads a hook's permissions from the low 14 bits of its address.
`0x695cfF9C7F11fa87ca05c7b0A0fa64C3554B3eCe` ends in `0x3ECE` = 16078 =
`getHookPermissions()`, which is:

`BEFORE_INITIALIZE | AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | AFTER_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA | AFTER_ADD_LIQUIDITY_RETURNS_DELTA`

No `beforeDonate` / `afterDonate` (they revert `HookNotImplemented`), no
`afterRemoveLiquidity` logic.

## Repository layout and build

```
v4src/                     the hook stack (production)
  ArcadeHook.sol           the hook: launches, bonding curve, graduation, fees
  libraries/               ArcadeHookLib, ArcadeRwaLib, ArcadeV4Math (linked), ArcadeV4Curve (internal math)
  ArcadeV4SwapRouter.sol   swap conduit
  LockedVault.sol          owner of record of locked positions
  ArcadeDividendDistributor.sol, CreatorSplitter.sol, HolderAirdropDistributor.sol
v4test/                    the hook test suite
src/launchpad/             ArcadeLaunchToken (the ERC20 every launch mints), ArcadeRwaLaunchToken, ArcadeTwitterEscrowV4
src/token/ArcadeToken.sol  the platform token
src/treasury/              ArcadeLpLocker, ArcadeBuybackVault
src/cctp/                  ArcadeCctpBuyReceiver (bridge and buy through CCTP V2)
deployments/mainnet.json   addresses
```

```sh
git clone --recursive https://github.com/obseasd/arcade-integrations
cd arcade-integrations
forge build                              # hook stack, the exact deployment settings
forge build --sizes                      # ArcadeHook: 24,153 bytes runtime
forge test                               # hook test suite, 273 tests
FOUNDRY_PROFILE=standalone forge build   # platform token, locker, vault, CCTP receiver
```

Compiler settings are the deployment settings and must not be changed if you
want matching bytecode: the hook stack uses solc 0.8.26, `via_ir`, 200
optimizer runs, `evm_version = cancun`, no metadata trailer; the standalone
profile uses solc 0.8.35, `via_ir`, 1 optimizer run, no metadata trailer.
Dependencies are git submodules pinned to the commits the monorepo builds
against: forge-std v1.16.1, OpenZeppelin v5.6.1, v4-core `46c68346`,
v4-periphery `363226d9`.

## Discovery: finding every launch

Everything starts at the hook.

- `tokensCount()` and `allTokens(i)` enumerate every launch token ever created,
  in creation order.
- `event TokenLaunched(address indexed token, address indexed creator, uint8 mode, string name, string symbol, string metadataURI)`
- `event LaunchCreated(PoolId indexed poolId, address indexed token, address creator, uint8 mode)`

Both events are declared in `ArcadeHook` and again in `ArcadeHookLib`; the
library runs by `delegatecall`, so on chain they are always emitted by the hook
address. Index from block 20,030,281.

Per-token state, all on the hook:

| Getter | Meaning |
| --- | --- |
| `registeredLaunches(token)` | true for every Arcade launch |
| `poolIdOf(token)` | the V4 `PoolId` |
| `quoteAssetOf(token)` | the quote currency; the zero address means USDC |
| `poolFeeOf(token)` | the pool's static LP fee (`fee` in the `PoolKey`) |
| `getCurveState(poolId)` | `mode`, `status`, `realUsdcReserve`, `tokensSold`, `creator` |
| `getFeeOwner(poolId)` | `creator`, `creator2`, `creator2Bps`, `feeTierBps`, `twitterEscrow`, `slotIndex` |
| `currentFeeBps(token)` | the hook's live trading fee on a graduated PUMP pool (bps), or the tier for CLANKER; 0 while not graduated |
| `currentSnipeBps(token)` | the live anti-sniper tax on buys (bps), 0 when none |
| `clankerPos(token)` | CLANKER: `tickLower`, `tickUpper`, `seeded`, `launchedAt` |
| `lastTradeAt(poolId)` | timestamp of the last swap on a graduated pool |

`mode` is `0` PUMP, `1` CLANKER, `3` RWA (`2`, CLANKER_V3, is rejected by
`createLaunch` and never existed on mainnet). `status` is `0` Curving,
`1` GraduationStarted, `2` Graduated.

## Building a launch's PoolKey

```solidity
address quote = hook.quoteAssetOf(token);
if (quote == address(0)) quote = 0x3600000000000000000000000000000000000000; // USDC
(address c0, address c1) = quote < token ? (quote, token) : (token, quote);
PoolKey({
    currency0:   Currency.wrap(c0),
    currency1:   Currency.wrap(c1),
    fee:         hook.poolFeeOf(token), // 0 for PUMP; 10000 / 20000 / 30000 for CLANKER (1 / 2 / 3 %)
    tickSpacing: 200,
    hooks:       IHooks(0x695cfF9C7F11fa87ca05c7b0A0fa64C3554B3eCe)
});
```

`hookData` is empty. The hook does not care who the swap sender is: any V4
router (the `ArcadeV4SwapRouter` below, the canonical Universal Router, your
own `unlock` callback) can trade a graduated pool.

Do not assume the quote is USDC. Since 2026-09-17 the protocol default quote
for CLANKER launches is the ARCADE token (`clankerQuote()` returns
`0xcaaD9713114A3c26131594E7e3a908f41e7d4549` and `clankerQuoteIsDefault()`
is true); a creator can still force USDC. An ARCADE-quoted pool has an
18-decimal quote and its `startMcap` bounds are expressed in ARCADE. Always
read `quoteAssetOf(token)` and the quote's `decimals()`.

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
   constant-product with virtual reserves (`ArcadeV4Curve`):
   `VIRTUAL_USDC_RESERVE` 5,500 USDC, `VIRTUAL_TOKEN_RESERVE` 1,094,200,000
   tokens, `CURVE_SUPPLY` 777,000,000 tokens sold on the curve, a 1 % fee on
   every curve trade (`TRADE_FEE_BPS`, split 50/50 creator/treasury). Quote
   with `ArcadeV4Curve.simulateBuy(tokensSold, realUsdcReserve, grossUsdcIn)`
   and `simulateSell(tokensSold, realUsdcReserve, tokensIn)`; the inputs come
   from `getCurveState`. Events: `CurveBuy(poolId, buyer, grossUsdcIn, tokensOut)`,
   `CurveSell(poolId, seller, tokensIn, usdcOut)`.
3. When the curve sells out (`realUsdcReserve` reaches about 13,473 USDC,
   `GRADUATION_USDC`) the buy that crosses the line graduates the token in the
   same transaction: a 1 % migration fee of the raise goes to the treasury
   (`MIGRATION_FEE_BPS`), the remaining 223,000,000 tokens plus the USDC seed a
   locked V4 position, and `Graduated(poolId, finalUsdcReserve, tokensInLP)` is
   emitted. `status` is `1` only inside that transaction.
4. After graduation the pool trades like any V4 pool with a static LP fee of 0
   (`poolFeeOf` = 0) and **the hook takes its fee in USDC on every swap**:
   `currentFeeBps(token)` of the USDC side, charged in `beforeSwap` when USDC is
   the specified currency and in `afterSwap` otherwise. The fee is 1 % at
   graduation (`PUMP_FEE_MAX_BPS`) and decays linearly in log market cap to a
   0.30 % floor (`PUMP_FEE_MIN_BPS`) once the pool's price EMA sits 23,026 ticks
   (10x) above the graduation tick. The EMA has a one-hour time constant and is
   updated at most once per block, after the fee is taken, so a swap never
   moves the fee it pays. The take is split 80 % creator / 20 % treasury
   (`POST_GRAD_CREATOR_BPS`); `RoyaltyPaid(poolId, creator, creatorAmount, treasuryAmount, currency)` carries both cuts and `SwapTreasuryFee(poolId, treasuryUsdc)` repeats
   the treasury part for indexers.
5. A creator can arm an anti-sniper tax at launch (`snipeStartBps` up to 50 %,
   decaying linearly to 0 over at most 3,600 s from graduation). It applies to
   quote-to-token buys only, on top of the fee, and is paid to the creator
   (`AntiSnipeApplied`). Read `currentSnipeBps(token)` before quoting a buy;
   hook fee plus tax are capped together at 60 % (`MAX_TOTAL_TAKE_BPS`).

### CLANKER (mode 1): direct single-sided locked liquidity

`createLaunch` with mode 1 mints the same 1,000,000,000-token ERC20, seeds a
single-sided position of the whole supply above the starting market cap
(`startMcapUsdc`, default 35,000 USDC, bounds 1,000 to 10,000,000 USDC; in the
quote's own units and the owner-set bounds when the quote is not USDC) and
locks it. The launch is `Graduated` from its first block and trades in the V4
pool immediately. The creator chooses the fee tier at launch: `feeTier` 1, 2 or
3, stored as the pool's **native LP fee** `poolFeeOf` = 10000 / 20000 / 30000.
**The hook takes nothing on CLANKER swaps**; `currentFeeBps(token)` simply
returns the tier. Anyone can call `collectFees(token)` to harvest the locked
position's accrued LP fees; they are split 80 / 20 creator / treasury in each
currency (`RoyaltyPaid` for both).

### RWA (mode 3): present, not open

`createRwaLaunch` pairs a launch with an allowed real-world-asset quote and
routes a creator-set trade tax (1 to 3 %, the pool's native LP fee) to holders
through `ArcadeDividendDistributor`. On mainnet no quote is allowed
(`setRwaQuoteAllowed` was never called), so `createRwaLaunch` reverts
`QuoteNotAllowed` and no RWA pool exists. Integrators can ignore mode 3 until
this changes; the discovery path is the same.

## Trading a graduated pool

`ArcadeV4SwapRouter` is a stateless, ownerless single-hop router:

```solidity
// approve the router for the input currency first
router.exactInputSingle(key, zeroForOne, amountIn, minAmountOut, recipient, 0 /* sqrtPriceLimitX96: 0 = no limit */);
router.exactOutputSingle(key, zeroForOne, amountOut, maxAmountIn, recipient, 0);
```

It emits `SwapExecuted(payer, recipient, inputCurrency, outputCurrency, amountIn, amountOut, zeroForOne)`
with the realised amounts and reverts `SlippageExceeded(actual, limit)` or
`IncompleteOutput(delivered, requested)`. The V4 quoter at
`0x338F2A7424af45BDD9AcF8E7F56423fbECEecfe6` simulates the full swap, so its
result already includes the hook's take.

## Limits and reverts to expect

| Situation | Revert |
| --- | --- |
| V4 swap on a PUMP token still on its curve | `LiquidityNotPermitted` |
| V4 swap during the graduation transaction | `GraduationInProgress` |
| `buy` / `sell` on a graduated (or CLANKER) token | `LiquidityNotPermitted` |
| `buy` / `sell` output below the caller's minimum | `Slippage` |
| CLANKER (and RWA) buy too large in the first five minutes | `BuyExceedsCap` |
| adding liquidity from anything but the hook | `LiquidityNotPermitted` |
| removing a locked position | `LockedPosition` |

The CLANKER buy cap: for 300 s after launch (`clankerPos(token).launchedAt`) a
single swap may deliver at most 1 % of the supply in the first minute, 2 % in
the second, up to 5 % in the fifth; after that there is no cap. The schedule is
fixed in code; the owner can only switch it off globally (`setClankerBuyCap`
with `maxBuyBps` = 0; it is on, 100 / 300, at the time of writing). The cap is
checked in `afterSwap`, so quotes are unaffected but the swap reverts.

There is no external liquidity: `beforeAddLiquidity` accepts only the hook
itself, and every position the hook seeds is locked (`positions(key).locked`)
with its ERC-6909 receipt owned by `LockedVault`, which has no code path to
move it. The one exception is `graveyardSweep(token)`: a graduated pool with no
swap for `graveyardPeriod()` (365 days, owner-adjustable but never below 180
days) can be swept once, by anyone, which pulls the residual liquidity to the
treasury and emits `GraveyardSwept`. A traded pool can never be swept.

## What the owner can and cannot do

The hook is `Ownable2Step`; the owner is the 2-of-3 Safe. `owner()` is
`0x55589b2eba875a6462f6Cf587058C4d4e317315b`, `pendingOwner()` is zero.

Setters that exist, all `onlyOwner`:

| Setter | Effect |
| --- | --- |
| `pause()` / `unpause()` | blocks `createLaunch`, `createRwaLaunch`, `buy`, `sell`, `collectFees`, `harvestRwaFees`. **Does not block V4 swaps**: `beforeSwap` and `afterSwap` are not pausable, a graduated pool keeps trading while paused |
| `setTreasury(address)` | where the protocol's fee share goes from then on |
| `setTwitterEscrow(address)` / `setTokenForwarder(address)` | fee destinations for handle-attributed launches (future launches) |
| `setDividendDistributor(address)` | one-time (`AlreadySet` afterwards) |
| `setClankerQuote(quote, defaultMcap, minMcap, maxMcap, makeDefault)` / `setClankerQuoteIsDefault(bool)` | the optional non-USDC quote and start-cap bounds for **future** CLANKER launches; an existing pool's quote is stored per token and never changes |
| `setRwaQuoteAllowed(asset, bool)` | allowlist of RWA quotes |
| `setRwaGraveyardSink(address)` | one-time |
| `setClankerBuyCap(maxBuyBps, windowSecs)` | the global on/off switch of the first-five-minutes cap |
| `setGraveyardPeriod(uint40)` | never below 180 days (`GraveyardPeriodTooShort`) |

What no owner action can do: change the fee of an existing pool (a CLANKER
tier is stored per launch, the PUMP schedule is compiled constants), take a
different cut than 80 / 20, block, pause or censor swaps on a graduated pool,
withdraw or move a locked position, mint tokens, or upgrade the hook. The
constants (`CREATION_FEE`, curve parameters, fee bounds, cap schedule) are
compiled in and the address is tied to this bytecode.

## Reference implementation

KyberSwap's aggregator integrates both trading paths; the pull requests are a
complete, reviewed reference for a quoting engine:

- [kyberswap-dex-lib #1674](https://github.com/KyberNetwork/kyberswap-dex-lib/pull/1674):
  the V4 hook (graduated PUMP pools with the USDC-side hook fee, CLANKER pools
  with the native fee, the buy cap).
- [kyberswap-dex-lib #1675](https://github.com/KyberNetwork/kyberswap-dex-lib/pull/1675):
  the PUMP bonding curve as a liquidity source (curve math, fees, anti-sniper).

## Data

Public subgraph (Goldsky), mainnet:

```
https://api.goldsky.com/api/public/project_cmrntot4nn29m01stbb661x1d/subgraphs/arcade-charts-mainnet/prod/gn
```

Entities:

- `Token`: `id creator mode poolFee createdAt migrated migratedAt migratedPair name symbol metadataURI totalVolumeUsdc tradeCount feesUsdc lastPriceUsdc usdcLiquidity holderCount`
- `Trade`: `id token trader source pool price volumeUsdc isBuy blockTime blockNumber logIndex protocolFeeUsdc`
- `V4Pool`: `id token creator mode tokensSold hook quoteReserve tokenReserve tvlUsdc liquidity sqrtLowerX96 sqrtUpperX96 quote quoteDecimals`
- `TokenHourData`: `id token hour volumeUsdc open high low close tradeCount`

```graphql
{
  tokens(first: 20, orderBy: createdAt, orderDirection: desc) {
    id name symbol mode poolFee migrated lastPriceUsdc usdcLiquidity
  }
}
```

The site publishes a machine-readable manifest of the live addresses, updated
with every deployment: <https://www.arcade.trading/deployments.json>.

## Licence

MIT for the Arcade sources (see `LICENSE`). Uniswap v4-core and v4-periphery
are pulled in as submodules under their own licences.

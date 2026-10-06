# MemesPad Uniswap v4 Hooks

Public source repository for the Uniswap v4 hooks used by MemesPad.

MemesPad is a multichain token launchpad that uses Uniswap v4 hooks to provide configurable on-chain swap fee handling, creator and platform rewards, automated token buyback and burn, holder dividends, automatic liquidity, and fair-launch protections.

---

## Legacy Hook — Arc

The legacy MemesPad Hook remains deployed and in use by the existing MEMESPAD/USDC Uniswap v4 pool on Arc.

### Deployment

- Chain: Arc
- Hook: `0xde81bE3A1AADEb9F01dFcf334f189901EF8600cC`
- Pool ID: `0x3b058ad6b939d04432d339f01bcefdcd5bce726a213950a42df3bb06434ab889`
- MEMESPAD: `0x0bB3bEFba323578DAd33EfB6356c69b557787777`
- USDC: `0x3600000000000000000000000000000000000000`

### Hook Functionality

The legacy MemesPad Hook applies configurable buy and sell fees during swaps and routes those fees on-chain between:

- Creator/platform rewards
- Automated token buyback and burn
- Holder dividends
- Automatic liquidity

The Hook also supports fair-launch protections including an anti-snipe window and maximum-buy protection during the initial launch period.

### Uniswap v4 Permissions

The legacy Hook uses:

- `beforeSwap`
- `afterSwap`
- `beforeSwapReturnDelta`
- `afterSwapReturnDelta`

The return-delta permissions are used to account for configured token fees during swap execution.

### Verification

The deployed Hook source is verified on the Arc block explorer.

---

## V2 Hook — Arc

The MemesPad V2 Hook is used by newly launched tokens on the MemesPad platform on Arc.

### Deployment

- Chain: Arc
- Hook: `0x5640A3a688c2bB745061a7D42430307e766d00cC`
- Example Pool ID: `0x3bd1ae4dfe1eff4cd38a38b557429d832ca22fe5c1e9b051723d702aa7b5a401`
- Example Token: `0x267702e2FD19Af533f7F55F0E06D5F7C41E87777`

### Hook Functionality

The MemesPad V2 Hook applies configurable buy and sell fees during swaps and routes those fees on-chain between:

- Creator/platform rewards
- Automated token buyback and burn
- Holder dividends
- Automatic liquidity

The Hook also supports configurable fair-launch protections, including an anti-snipe window and maximum-buy protection during the initial launch period.

### Uniswap v4 Permissions

The V2 Hook uses:

- `beforeSwap`
- `afterSwap`
- `beforeSwapReturnDelta`
- `afterSwapReturnDelta`

The return-delta permissions are used to account for configured token fees during swap execution.

### Source

The complete V2 Hook source is available in the `/V2` directory of this repository.

### Verification

The deployed Hook source is verified on the Arc block explorer.

---

# MemesPad Hook — Robinhood Chain

The MemesPad Uniswap v4 Hook deployed on Robinhood Chain is used by tokens launched through the MemesPad multichain launchpad.

The Hook provides configurable swap fee collection and on-chain fee routing while integrating directly with the Uniswap v4 PoolManager.

## Deployment

- Chain: Robinhood Chain
- Chain ID: `4663`
- MemespadHook: `0x1D79cbF0B67642a6350aff0E3c7D904E77E640cc`
- MemespadFactory: `0x07610c8b5e932A7C87D19882e942b3737527Dd87`
- MemespadTax: `0x8C090B415Cc46Df386F768EB1b86be61cb238e98`
- MemespadDividendPool: `0x581860bd212D79FE6757F252571f4aF5eC33fAFB`
- MemespadTokenDeployer: `0x8f31e91F46B1C0D93D939af24dFD42cC6e2f64D0`
- MemespadReferrals: `0x263420927E2ad300b618Db9C3bAB3Aed3be5b234`
- Uniswap v4 PoolManager: `0x8366a39CC670B4001A1121B8F6A443A643e40951`
- Uniswap v4 StateView: `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b`

## Hook Functionality

The Robinhood MemesPad Hook provides configurable on-chain fee handling for tokens launched through MemesPad.

Each registered token can have independently configured buy and sell fees.

Fees collected by the Hook can be allocated between:

- Creator rewards
- Platform fees
- Automated token buyback and burn
- Holder dividends
- Automatic liquidity

The allocation configuration is stored per registered token.

## Uniswap v4 Permissions

The Robinhood Hook uses:

- `beforeSwap`
- `afterSwap`
- `beforeSwapReturnDelta`
- `afterSwapReturnDelta`

All other Uniswap v4 Hook permissions are disabled.

The return-delta permissions are used as part of the Hook's configurable swap-fee collection and settlement logic.

The Hook address is deployed with the required Uniswap v4 permission bits corresponding to these permissions.

## Swap Fee Handling

For registered tokens, the Hook determines whether a swap is a buy or sell and applies the configured buy or sell tax.

The Hook supports fee collection through both the `beforeSwap` and `afterSwap` paths depending on which asset is specified by the swap.

Collected fees are routed according to the registered token's allocation configuration.

## Fee Configuration

The Hook contract enforces the following limits:

- Maximum configurable buy tax: 10%
- Maximum configurable sell tax: 10%
- Minimum platform allocation: 30% of collected tax
- Maximum configurable fair-launch window: 3,600 seconds

Individual launched tokens can use configurations below these maximum values.

## Creator and Platform Fees

A configurable portion of the swap fee can be allocated to the token creator.

The remaining platform allocation is routed through the MemespadTax contract.

The Hook enforces a minimum platform share of the collected swap tax.

## Automated Buyback and Burn

A configurable portion of collected fees can accumulate in a buyback-and-burn bucket.

When the configured threshold is reached, the Hook uses the accumulated quote asset to execute a swap through the associated Uniswap v4 pool.

Tokens acquired through the buyback are transferred to:

`0x000000000000000000000000000000000000dEaD`

This provides an on-chain automated buyback-and-burn mechanism.

## Holder Dividends

A configurable portion of collected fees can accumulate in the dividend bucket.

Once the configured dividend threshold is reached, the accumulated quote asset is forwarded to the MemesPad Dividend Pool.

The Dividend Pool is responsible for the associated holder reward distribution system.

## Automatic Liquidity

A configurable portion of collected fees can accumulate for automatic liquidity.

When the configured liquidity threshold is reached, the Hook:

1. Uses part of the accumulated quote asset to acquire the launched token.
2. Calculates the appropriate liquidity using the current Uniswap v4 pool price and configured tick range.
3. Adds liquidity directly through the Uniswap v4 PoolManager.
4. Handles unused token and quote-asset amounts according to the Hook's liquidity logic.

The resulting liquidity position is controlled directly through the Hook's PoolManager liquidity accounting.

## Fair-Launch Protection

The Hook includes configurable fair-launch protections for newly registered tokens.

These include:

### Anti-Snipe Protection

A token can be registered with a snipe-protection period.

During the configured period, normal external buys can be prevented while launch initialization operations remain permitted.

### Maximum-Buy Protection

The Hook can enforce a maximum quote-asset amount for buys during the initial fair-launch period.

The maximum-buy amount can be configured independently for each quote token.

## Token Registration

Tokens are registered with the Hook through the MemespadFactory.

Registration defines parameters including:

- Buy tax
- Sell tax
- Creator allocation
- Buyback-and-burn allocation
- Dividend allocation
- Automatic-liquidity allocation
- Burn threshold
- Dividend threshold
- Liquidity threshold
- Fair-launch timing

The Hook retrieves the associated quote token and token ordering from the MemespadFactory.

## Administration

The Hook includes administrative configuration functions for maintaining platform parameters, including:

- Treasury address
- Factory address
- Dividend Pool address
- Token buy/sell tax
- Fee allocations
- Burn thresholds
- Dividend thresholds
- Liquidity thresholds
- Fair-launch duration
- Maximum-buy limits
- Liquidity tick ranges

Administrative functions are restricted to the Hook owner where applicable.

## Events

The Hook emits on-chain events for important operations including:

- Token registration
- Swaps
- Buyback and burn execution
- Dividend transfers
- Automatic liquidity additions
- Tax updates
- Allocation updates
- Threshold updates
- Fair-launch configuration updates

These events provide on-chain visibility into Hook activity.

## Source

The complete Robinhood Chain Hook source and its required local dependencies are available in the `/Robinhood` directory of this repository.

The directory contains:

```text
Robinhood/
├── MemespadHook.sol
├── interfaces/
│   └── IV4.sol
└── libraries/
    ├── TickMath.sol
    └── LiquidityMath.sol

# MemesPad Uniswap v4 Hooks

Public source repository for the Uniswap v4 hooks used by MemesPad.

## Legacy Hook

The legacy MemesPad Hook remains deployed and in use by the existing MEMESPAD/USDC Uniswap v4 pool on Arc.

### Deployment

- Chain: Arc
- Hook: `0xde81bE3A1AADEb9F01dFcf334f189901EF8600cC`
- Pool ID: `0x3b058ad6b939d04432d339f01bcefdcd5bce726a213950a42df3bb06434ab889`
- MEMESPAD: `0x0bB3bEFba323578DAd33EfB6356c69b557787777`
- USDC: `0x3600000000000000000000000000000000000000`

### Hook Functionality

The MemesPad Hook applies configurable buy and sell fees during swaps and routes those fees on-chain between:

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

## Current Hook

MemesPad also operates a newer v4 Hook used by newly launched tokens. Its verified source and deployment information will be added separately.

## Verification

The deployed Hook source is verified on the Arc block explorer.

## License

MIT


## Current V2 Hook

The current MemesPad V2 Hook is used by newly launched tokens on the MemesPad platform.

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

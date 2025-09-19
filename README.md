## TrunkGuard: FHE-Powered Uniswap v4 Hook

Private, MEV-resistant swaps on Uniswap v4 using Fhenix Fully Homomorphic Encryption (FHE).

This repo contains a Uniswap v4 hook that validates encrypted orders and records encrypted outputs, plus a simple FHE-enabled ERC20 used in tests and scripts.

---

### What’s integrated

- Uniswap v4 hooks via `BaseHook` in `src/TrunkGuardSwapHook.sol`
- Fhenix CoFHE contracts via `@fhenixprotocol/cofhe-contracts/FHE.sol`
- Foundry-based tests with CoFHE mocks via `cofhe-foundry-mocks`

---

## Where Fhenix is used (and how)

Files:

- `src/TrunkGuardSwapHook.sol`

  - Imports: `import {FHE, euint128, ebool, Common} from "@fhenixprotocol/cofhe-contracts/FHE.sol";`
  - Stores encrypted inputs/outputs per pool and order:
    - `mapping(PoolId => mapping(bytes32 => euint128)) public encryptedOrders;`
    - `mapping(PoolId => mapping(bytes32 => euint128)) public encryptedMinOutputs;`
    - `mapping(PoolId => mapping(bytes32 => euint128)) public encryptedOutputs;`
    - `mapping(PoolId => mapping(bytes32 => ebool))    public swapValidations;`
  - Accepts encrypted inputs via:
    - `submitEncryptedSwap(PoolKey key, euint128 encAmount, euint128 encMinOutput, bytes data)`
  - Validates homomorphically inside `_beforeSwap`:
    - Computes expected output with `FHE.mul(encAmount, encPrice)`
    - Compares via `FHE.gte(expectedOutput, encMinOutput)` to produce an `ebool`
  - Records `BalanceDelta` in `_afterSwap` (as encrypted output)
  - Off-chain decryption flow helpers:
    - `validateSwap`, `requestOutputDecryption`, `revealOutput`

- `src/HybridFHERC20.sol`
  - Example token used in tests/scripts; standard ERC20-like interface with helper mints

Key concepts:

- `euint128`, `ebool` are encrypted integer/boolean types
- Use `Common.isInitialized(x)` to check if encrypted values are set
- Use `FHE.asEuint128(value)` to create encrypted constants on-chain

---

## Where Uniswap v4 is used (and how)

Files:

- `src/TrunkGuardSwapHook.sol`

  - Inherits `BaseHook` and implements:
    - `_beforeSwap(…) internal override returns (bytes4, BeforeSwapDelta, uint24)`
    - `_afterSwap(…)  internal override returns (bytes4, int128)`
  - Reads pool state via `IPoolManager` and `StateLibrary` (e.g. `getSlot0(key.toId())`)

- Tests and setup use v4-core helpers via `test/utils` and Foundry fixtures.

Hook address permissions:

- Uniswap v4 encodes permissions in the least-significant 14 bits of the hook’s address (see `@uniswap/v4-core/src/libraries/Hooks.sol`).
- For this hook we require at minimum:
  - `Hooks.BEFORE_SWAP_FLAG`
  - `Hooks.AFTER_SWAP_FLAG`
  - optionally `Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG` if returning deltas

Deploying to a valid address (tests):

- Use `HookMiner.find` from `v4-periphery` to generate a CREATE2 salt that yields an address with the proper flags.
- Example (see comments in `test/TrunkGuardSwapHook.t.sol`):
  - `(address hookAddress, bytes32 salt) = HookMiner.find(deployer, flags, type(TrunkGuardSwapHook).creationCode, abi.encode(manager));`
  - `new TrunkGuardSwapHook{salt: salt}(manager)` and assert `address(hook) == hookAddress`

Troubleshooting `SenderNotAllowed` / `HookAddressNotValid`:

- These revert when the hook address does not encode the required flags
- Always deploy the hook to an address returned by `HookMiner.find`
- Ensure you pass the same constructor args to both `find` and `new … {salt: …}`

---

## Project layout

```
trunkGuard/
├─ src/
│  ├─ TrunkGuardSwapHook.sol        # Main FHE-enabled Uniswap v4 hook
│  ├─ HybridFHERC20.sol             # Simple token used for local tests/scripts
│  └─ interface/
│     └─ IFHERC20.sol
├─ test/
│  ├─ TrunkGuardSwapHook.t.sol      # Core tests (Foundry + CoFHE mocks)
│  └─ utils/…                       # Uniswap v4 testing utilities
├─ script/
│  ├─ 01_CreatePoolAndMintLiquidity.s.sol
│  ├─ 01a_CreatePoolOnly.s.sol
│  ├─ 02_AddLiquidity.s.sol
│  ├─ 03_Swap.s.sol                 # Simple swap script
│  └─ Anvil.s.sol                   # Local end-to-end demo
├─ foundry.toml
├─ hardhat.config.ts
└─ remappings.txt
```

---

## Quickstart (local)

Prereqs:

- Foundry (forge, anvil)
- Node.js (for installing packages if needed)

Install and build:

```bash
pnpm install || npm install
forge build
```

Run tests:

```bash
forge test -vv
```

Run local demo on Anvil:

```bash
anvil --gas-limit 30000000 &
forge script script/Anvil.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast
```

Swap-only demo:

```bash
forge script script/03_Swap.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast
```

---

## Notes on tests

- Tests inherit `CoFheTest` from `cofhe-foundry-mocks` to simulate FHE flows
- You may mock decryption results via the mock task manager helpers if needed
- If you see `SenderNotAllowed` or `HookAddressNotValid` during pool init:
  - Switch to `HookMiner.find` deployment flow in `setUp()` and re-run

---

## Extending this repo

- Add richer validation logic in `_beforeSwap`
- Extend `revealOutput` to emit decrypted outputs after authorized reveal
- Expand scripts to demonstrate multi-pool scenarios

---

## License

MIT. See `LICENSE`.

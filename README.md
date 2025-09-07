# fhe-hook-template
### **A template for writing Uniswap FHE-Enabled v4 Hooks 🔒🦄**

> Bridging private computation and public liquidity with Fully Homomorphic Encryption in Uniswap v4 Hooks.

[`Use this Template`](https://github.com/marronjo/fhe-hook-template/generate)

1. The example hook [Counter.sol](src/Counter.sol) demonstrates basic FHE computation in the `beforeSwap()`, `afterSwap()`, `_beforeAddLiquidity()` and `_beforeRemoveLiquidity()` hooks. It simply adds encrypted '1' to the counter in each hook.
2. The test template [Counter.t.sol](test/Counter.t.sol) preconfigures the v4 pool manager, test FHE-enabled tokens and test liquidity.

<details>
<summary>Updating to v4-template:latest</summary>

This template is actively maintained -- you can update the v4 dependencies, scripts, and helpers: 
```bash
git remote add template https://github.com/marronjo/fhe-hook-template
git fetch template
git merge template/main <BRANCH> --allow-unrelated-histories
```

</details>

---

### Check Forge Installation
*Ensure that you have correctly installed Foundry (Forge) Stable. You can update Foundry by running:*

```
foundryup
```

> *v4-template* appears to be _incompatible_ with Foundry Nightly. See [foundry announcements](https://book.getfoundry.sh/announcements) to revert back to the stable build



## Set up

*requires [foundry](https://book.getfoundry.sh)*

```bash
#use node for dependencies
npm install

forge test --via-ir
```

### Local Development (Anvil)

Other than writing unit tests (recommended!), you can only deploy & test hooks on [anvil](https://book.getfoundry.sh/anvil/)

```bash
# start anvil, a local EVM chain
anvil

# in a new terminal
forge script script/Anvil.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --broadcast
```

See [script/](script/) for hook deployment, pool creation, liquidity provision, and swapping.

---

<details>
<summary><h2>Troubleshooting</h2></summary>

### *Permission Denied*

When installing dependencies with `forge install`, Github may throw a `Permission Denied` error

Typically caused by missing Github SSH keys, and can be resolved by following the steps [here](https://docs.github.com/en/github/authenticating-to-github/connecting-to-github-with-ssh) 

Or [adding the keys to your ssh-agent](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#adding-your-ssh-key-to-the-ssh-agent), if you have already uploaded SSH keys

### Anvil fork test failures

Some versions of Foundry may limit contract code size to ~25kb, which could prevent local tests to fail. You can resolve this by setting the `code-size-limit` flag

```
anvil --code-size-limit 40000
```

### Hook deployment failures

Hook deployment failures are caused by incorrect flags or incorrect salt mining

1. Verify the flags are in agreement:
    * `getHookCalls()` returns the correct flags
    * `flags` provided to `HookMiner.find(...)`
2. Verify salt mining is correct:
    * In **forge test**: the *deployer* for: `new Hook{salt: salt}(...)` and `HookMiner.find(deployer, ...)` are the same. This will be `address(this)`. If using `vm.prank`, the deployer will be the pranking address
    * In **forge script**: the deployer must be the CREATE2 Proxy: `0x4e59b44847b379578588920cA78FbF26c0B4956C`
        * If anvil does not have the CREATE2 deployer, your foundry may be out of date. You can update it with `foundryup`

</details>

---

## 📖 Resources

Fhenix 🔒
- [FHE Limit Order Hook](https://github.com/marronjo/iceberg-cofhe)
- [CoFhe docs](https://cofhe-docs.fhenix.zone/docs/devdocs/overview)
- [FHERC20 Token Docs](https://cofhe-docs.fhenix.zone/docs/devdocs/fherc/fherc20)

Uniswap 🦄
- [Hook Examples](https://github.com/Uniswap/v4-periphery/tree/example-contracts/contracts/hooks/examples)
- [Uniswap v4 docs](https://docs.uniswap.org/contracts/v4/overview)  
- [v4-periphery](https://github.com/uniswap/v4-periphery)  
- [v4-core](https://github.com/uniswap/v4-core)  
- [v4-by-example](https://v4-by-example.org)  


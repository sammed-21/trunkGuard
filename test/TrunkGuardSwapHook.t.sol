// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Foundry Imports
import "forge-std/Test.sol";

// Uniswap Imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SortTokens} from "./utils/SortTokens.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// FHE Imports
import {FHE, InEuint128, euint128, ebool, Common} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {CoFheTest} from "@fhenixprotocol/cofhe-foundry-mocks/CoFheTest.sol";

// Hook Contract
import {TrunkGuardSwapHook} from "../src/TrunkGuardSwapHook.sol";
import {HybridFHERC20} from "../src/HybridFHERC20.sol";

contract TrunkGuardSwapHookTest is Test, Fixtures, CoFheTest {
    constructor() CoFheTest(false) {}
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    TrunkGuardSwapHook hook;
    address hookAddr;
    PoolId poolId;

    HybridFHERC20 token0;
    HybridFHERC20 token1;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    uint128 private constant AMOUNT_1E8 = 1e8;
    uint128 private constant MIN_OUTPUT_1E7 = 1e7;
    uint128 private constant HIGH_MIN_OUTPUT = 1e18; // For failure test
    bool private constant ZERO_FOR_ONE = true;
    bool private constant ONE_FOR_ZERO = false;

    function setUp() public {
        // Step 1 + 2: Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our FHE-compatible tokens
        token0 = new HybridFHERC20("Token0", "TOK0");
        token1 = new HybridFHERC20("Token1", "TOK1");

        // Wrap tokens as currencies
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Mint tokens to ourselves
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);

        // Deploy hook directly for testing
        hook = new TrunkGuardSwapHook(manager);
        hookAddr = address(hook);

        // Approve tokens for spending on the swap router and modify liquidity router
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool without hook for testing
        (key, poolId) = initPool(
            currency0, // Currency 0
            currency1, // Currency 1
            IHooks(address(0)), // No hook for now
            3000, // Swap Fees
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );

        // Add some liquidity to the pool
        tickLower = -60;
        tickUpper = 60;

        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint256 amount0ToAdd = 1 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            SQRT_PRICE_1_1,
            sqrtPriceAtTickUpper,
            amount0ToAdd
        );

        modifyLiquidityRouter.modifyLiquidity{value: amount0ToAdd}(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        vm.label(hookAddr, "hook");
        vm.label(address(this), "test");
        vm.label(address(token0), "token0");
        vm.label(address(token1), "token1");
    }

    function test_submitEncryptedSwapBalances() public {
        (uint256 t0, uint256 t1, uint256 h0, uint256 h1) = _getBalances();

        euint128 encAmount = FHE.asEuint128(AMOUNT_1E8);
        euint128 encMinOutput = FHE.asEuint128(MIN_OUTPUT_1E7);
        hook.submitEncryptedSwap(key, encAmount, encMinOutput, ZERO_BYTES);

        (uint256 t2, uint256 t3, uint256 h2, uint256 h3) = _getBalances();

        assertEq(t0, t2);
        assertEq(t1, t3);
        assertEq(h0, h2);
        assertEq(h1, h3);
    }

    function test_encryptedOrderStored() public {
        euint128 encAmount = FHE.asEuint128(AMOUNT_1E8);
        euint128 encMinOutput = FHE.asEuint128(MIN_OUTPUT_1E7);
        hook.submitEncryptedSwap(key, encAmount, encMinOutput, ZERO_BYTES);

        bytes32 orderHash = keccak256(
            abi.encode(address(this), key, encAmount)
        );
        euint128 storedAmount = hook.encryptedOrders(poolId, orderHash);
        euint128 storedMinOutput = hook.encryptedMinOutputs(poolId, orderHash);

        assertTrue(Common.isInitialized(storedAmount));
        assertTrue(Common.isInitialized(storedMinOutput));
        assertHashValue(storedAmount, AMOUNT_1E8);
        assertHashValue(storedMinOutput, MIN_OUTPUT_1E7);
    }

    function test_swapExecution() public {
        (uint256 t0, uint256 t1, , ) = _getBalances();

        euint128 encAmount = FHE.asEuint128(AMOUNT_1E8);
        euint128 encMinOutput = FHE.asEuint128(MIN_OUTPUT_1E7);
        hook.submitEncryptedSwap(key, encAmount, encMinOutput, ZERO_BYTES);

        bytes32 orderHash = keccak256(
            abi.encode(address(this), key, encAmount)
        );

        vm.warp(block.timestamp + 11); // Simulate decryption time

        _swap(ZERO_FOR_ONE, int256(uint256(AMOUNT_1E8))); // Perform swap

        (uint256 t2, uint256 t3, , ) = _getBalances();

        assertLt(t2, t0); // token0 decreases
        assertGt(t3, t1); // token1 increases

        // Test hook functions directly (not through pool manager)
        // Check encrypted output stored
        euint128 encOutput = hook.encryptedOutputs(poolId, orderHash);
        assertTrue(Common.isInitialized(encOutput));

        // Validate swap
        hook.validateSwap(key, orderHash); // Should pass if minOutput is met

        // Request decryption for output
        hook.requestOutputDecryption(key, orderHash);

        vm.warp(block.timestamp + 11);

        hook.revealOutput(key, orderHash); // Should reveal the output
    }

    function test_swapValidationFailed() public {
        euint128 encAmount = FHE.asEuint128(AMOUNT_1E8);
        euint128 encMinOutput = FHE.asEuint128(HIGH_MIN_OUTPUT); // High min to fail
        hook.submitEncryptedSwap(key, encAmount, encMinOutput, ZERO_BYTES);

        bytes32 orderHash = keccak256(
            abi.encode(address(this), key, encAmount)
        );

        vm.warp(block.timestamp + 11);

        _swap(ZERO_FOR_ONE, int256(uint256(AMOUNT_1E8))); // Perform swap

        vm.expectRevert("Swap validation failed");
        hook.validateSwap(key, orderHash);
    }

    // ---------------------------
    //
    //      Helper Functions
    //
    // ---------------------------

    function _getBalances()
        private
        view
        returns (uint256 t0, uint256 t1, uint256 h0, uint256 h1)
    {
        t0 = token0.balanceOf(address(this));
        t1 = token1.balanceOf(address(this));
        h0 = token0.balanceOf(hookAddr);
        h1 = token1.balanceOf(hookAddr);
    }

    function _swap(
        bool zeroForOne,
        int256 amount
    ) private returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        return swapRouter.swap(key, params, _defaultTestSettings(), ZERO_BYTES);
    }

    function _defaultTestSettings()
        internal
        pure
        returns (PoolSwapTest.TestSettings memory testSetting)
    {
        return
            PoolSwapTest.TestSettings({
                takeClaims: true,
                settleUsingBurn: false
            });
    }
}

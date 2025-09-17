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
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

// FHE Imports
import {FHE, InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-foundry-mocks/CoFheTest.sol";

// Hook to Test
import {TrunkGuardSwapHook} from "../src/TrunkGuardSwapHook.sol";
import {HybridFHERC20} from "../src/HybridFHERC20.sol";

contract PrivacySwapHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    CoFheTest CFT;
    TrunkGuardSwapHook hook;
    PoolId poolId;
    PoolKey key;

    HybridFHERC20 fheToken0;
    HybridFHERC20 fheToken1;
    Currency fheCurrency0;
    Currency fheCurrency1;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    address user = makeAddr("user");

    function setUp() public {
        // Initialize CoFheTest
        CFT = new CoFheTest(false);

        // Deploy FHE-compatible tokens
        bytes memory token0Args = abi.encode("TOKEN0", "TOK0");
        deployCodeTo(
            "HybridFHERC20.sol:HybridFHERC20",
            token0Args,
            address(123)
        );
        bytes memory token1Args = abi.encode("TOKEN1", "TOK1");
        deployCodeTo(
            "HybridFHERC20.sol:HybridFHERC20",
            token1Args,
            address(456)
        );

        fheToken0 = HybridFHERC20(address(123));
        fheToken1 = HybridFHERC20(address(456));

        vm.label(user, "user");
        vm.label(address(this), "test");
        vm.label(address(fheToken0), "token0");
        vm.label(address(fheToken1), "token1");

        deployFreshManagerAndRouters();
        deployAndApprovePosm(manager);

        vm.startPrank(user);
        (fheCurrency0, fheCurrency1) = mintAndApprove2Currencies(
            address(fheToken0),
            address(fheToken1)
        );

        // Deploy hook
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^
                (0x4444 << 144)
        );
        bytes memory constructorArgs = abi.encode(manager);
        deployCodeTo(
            "TrunkGuardSwapHook.sol:TrunkGuardSwapHook",
            constructorArgs,
            flags
        );
        hook = TrunkGuardSwapHook(flags);
        vm.label(address(hook), "hook");

        // Create pool
        key = PoolKey(fheCurrency0, fheCurrency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide liquidity
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts
            .getAmountsForLiquidity(
                SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidityAmount
            );

        (tokenId, ) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );

        vm.stopPrank();
    }

    function testPrivateSwapAndDecryption() public {
        // Mock encrypted inputs
        uint256 amount = 1e18; // 1 ETH
        uint256 minOutput = 0.9e18; // 0.9 ETH
        euint128 encAmount = FHE.asEuint128(amount);
        euint128 encMinOutput = FHE.asEuint128(minOutput);

        // Submit encrypted swap
        vm.startPrank(user);
        vm.expectEmit(true, true, false, true);
        emit SwapSubmitted(
            user,
            keccak256(abi.encode(user, key, encAmount)),
            poolId
        );
        hook.submitEncryptedSwap(key, encAmount, encMinOutput, ZERO_BYTES);

        // Verify encrypted state
        bytes32 orderHash = keccak256(abi.encode(user, key, int256(amount)));
        CFT.assertHashValue(hook.encryptedOrders(poolId, orderHash), amount);
        CFT.assertHashValue(
            hook.encryptedMinOutputs(poolId, orderHash),
            minOutput
        );

        // Simulate swap
        vm.prank(address(manager));
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: 0
        });
        BalanceDelta swapDelta = swap(
            key,
            params.zeroForOne,
            params.amountSpecified,
            ZERO_BYTES
        );

        // Verify swap executed
        assertEq(int256(swapDelta.amount0()), params.amountSpecified);
        CFT.assertHashValue(hook.encryptedOrders(poolId, orderHash), 0); // Cleared
        CFT.assertHashValue(hook.encryptedMinOutputs(poolId, orderHash), 0); // Cleared

        // Verify encrypted output
        uint256 outputAmount = uint256(-swapDelta.amount1());
        CFT.assertHashValue(
            hook.encryptedOutputs(poolId, orderHash),
            outputAmount
        );

        // Request decryption
        vm.expectEmit(true, true, false, true);
        emit OutputDecryptionRequested(orderHash, poolId);
        hook.requestOutputDecryption(key, orderHash);

        // Mock decryption readiness (in production, wait for Fhenix network)
        vm.mockCall(
            address(FHE),
            abi.encodeWithSelector(
                FHE.getDecryptResultSafe.selector,
                hook.encryptedOutputs(poolId, orderHash)
            ),
            abi.encode(outputAmount, true)
        );

        // Reveal output
        vm.expectEmit(true, true, false, true);
        emit OutputRevealed(orderHash, poolId, uint128(outputAmount));
        hook.revealOutput(key, orderHash);
        CFT.assertHashValue(hook.encryptedOutputs(poolId, orderHash), 0); // Cleared
    }

    function testInvalidPrivateSwap() public {
        // Mock encrypted inputs with high minOutput
        uint256 amount = 1e18;
        uint256 minOutput = 10e18; // Unrealistic
        euint128 encAmount = FHE.asEuint128(amount);
        euint128 encMinOutput = FHE.asEuint128(minOutput);

        vm.startPrank(user);
        hook.submitEncryptedSwap(key, encAmount, encMinOutput, ZERO_BYTES);

        vm.prank(address(manager));
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: 0
        });
        vm.expectRevert("Private min output not met");
        swap(key, params.zeroForOne, params.amountSpecified, ZERO_BYTES);
    }

    function testRevealWithoutDecryption() public {
        uint256 amount = 1e18;
        uint256 minOutput = 0.9e18;
        euint128 encAmount = FHE.asEuint128(amount);
        euint128 encMinOutput = FHE.asEuint128(minOutput);

        vm.startPrank(user);
        hook.submitEncryptedSwap(key, encAmount, encMinOutput, ZERO_BYTES);

        vm.prank(address(manager));
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: 0
        });
        swap(key, params.zeroForOne, params.amountSpecified, ZERO_BYTES);

        bytes32 orderHash = keccak256(abi.encode(user, key, int256(amount)));
        hook.requestOutputDecryption(key, orderHash);

        // Mock decryption not ready
        vm.mockCall(
            address(FHE),
            abi.encodeWithSelector(
                FHE.getDecryptResultSafe.selector,
                hook.encryptedOutputs(poolId, orderHash)
            ),
            abi.encode(0, false)
        );

        vm.expectRevert("Output not yet decrypted");
        hook.revealOutput(key, orderHash);
    }

    // Helper: Mint and approve tokens
    function mintAndApprove2Currencies(
        address tokenA,
        address tokenB
    ) internal returns (Currency, Currency) {
        Currency _currencyA = mintAndApproveCurrency(tokenA);
        Currency _currencyB = mintAndApproveCurrency(tokenB);
        (currency0, currency1) = SortTokens.sort(
            Currency.unwrap(_currencyA),
            Currency.unwrap(_currencyB)
        );
        return (currency0, currency1);
    }
}

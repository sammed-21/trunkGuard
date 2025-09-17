// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Uniswap Imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

// FHE Imports
import {FHE, InEuint128, euint128, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

contract TrunkGuardSwapHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using FHE for uint256;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    // Store encrypted orders and outputs
    mapping(PoolId => mapping(bytes32 => euint128)) public encryptedOrders;
    mapping(PoolId => mapping(bytes32 => euint128)) public encryptedMinOutputs;
    mapping(PoolId => mapping(bytes32 => euint128)) public encryptedOutputs;

    // Events for Hackathon demo
    event SwapSubmitted(
        address indexed user,
        bytes32 indexed orderHash,
        PoolId poolId
    );
    event OutputDecryptionRequested(bytes32 indexed orderHash, PoolId poolId);
    event OutputRevealed(
        bytes32 indexed orderHash,
        PoolId poolId,
        uint128 amount
    );

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Submit encrypted swap
    function submitEncryptedSwap(
        PoolKey calldata key,
        euint128 encryptedAmount,
        euint128 encryptedMinOutput,
        bytes calldata hookData
    ) external {
        bytes32 orderHash = keccak256(
            abi.encode(msg.sender, key, encryptedAmount)
        );
        PoolId poolId = key.toId();

        encryptedOrders[poolId][orderHash] = encryptedAmount;
        encryptedMinOutputs[poolId][orderHash] = encryptedMinOutput;
        FHE.allowThis(encryptedOrders[poolId][orderHash]);
        FHE.allowThis(encryptedMinOutputs[poolId][orderHash]);

        // Trigger swap
        SwapParams memory params = SwapParams({
            zeroForOne: true, // Token0 -> Token1
            amountSpecified: int256(uint256(FHE.decrypt(encryptedAmount))), // Decrypt for PoolManager
            sqrtPriceLimitX96: 0
        });
        emit SwapSubmitted(msg.sender, orderHash, poolId);
        poolManager.swap(key, params, hookData);
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        bytes32 orderHash = keccak256(
            abi.encode(sender, key, params.amountSpecified)
        );

        // Get encrypted order data
        euint128 encryptedAmount = encryptedOrders[poolId][orderHash];
        euint128 encryptedMinOutput = encryptedMinOutputs[poolId][orderHash];

        // Get current pool price (simplified; use TWAP for production)
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key);
        euint128 encCurrentPrice = FHE.asEuint128(uint256(sqrtPriceX96));

        // Homomorphic check: output >= minOutput
        euint128 expectedOutput = encryptedAmount.mul(encCurrentPrice);
        ebool isValid = expectedOutput.ge(encryptedMinOutput);
        require(FHE.decrypt(isValid), "Private min output not met");

        // Clear order after validation
        delete encryptedOrders[poolId][orderHash];
        delete encryptedMinOutputs[poolId][orderHash];

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        bytes32 orderHash = keccak256(
            abi.encode(sender, key, params.amountSpecified)
        );

        // Store encrypted output
        euint128 encOutput = FHE.asEuint128(uint256(delta.amount1()));
        encryptedOutputs[poolId][orderHash] = encOutput;
        FHE.allowThis(encryptedOutputs[poolId][orderHash]);

        return (BaseHook.afterSwap.selector, 0);
    }

    // Step 1: Request on-chain decryption
    function requestOutputDecryption(
        PoolKey calldata key,
        bytes32 orderHash
    ) external {
        PoolId poolId = key.toId();
        euint128 encOutput = encryptedOutputs[poolId][orderHash];
        require(FHE.decrypt(encOutput) > 0, "No output to decrypt");
        FHE.decrypt(encOutput); // Request decryption
        emit OutputDecryptionRequested(orderHash, poolId);
    }

    // Step 2: Process decrypted result
    function revealOutput(PoolKey calldata key, bytes32 orderHash) external {
        PoolId poolId = key.toId();
        euint128 encOutput = encryptedOutputs[poolId][orderHash];
        (uint128 outputAmount, bool isReady) = FHE.getDecryptResultSafe(
            encOutput
        );
        require(isReady, "Output not yet decrypted");

        delete encryptedOutputs[poolId][orderHash];
        emit OutputRevealed(orderHash, poolId, outputAmount);
        // Transfer logic (e.g., FHERC20) can be added here
    }
}

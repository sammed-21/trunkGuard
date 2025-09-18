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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// FHE Imports
import {FHE, InEuint128, euint128, ebool, Common} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

contract TrunkGuardSwapHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using FHE for *;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using StateLibrary for IPoolManager;

    // Store encrypted orders, validations, and outputs
    mapping(PoolId => mapping(bytes32 => euint128)) public encryptedOrders;
    mapping(PoolId => mapping(bytes32 => euint128)) public encryptedMinOutputs;
    mapping(PoolId => mapping(bytes32 => euint128)) public encryptedOutputs;
    mapping(PoolId => mapping(bytes32 => ebool)) public swapValidations;

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

    // Submit encrypted swap (store only; actual swap is performed by caller/test router)
    function submitEncryptedSwap(
        PoolKey calldata key,
        euint128 encryptedAmount,
        euint128 encryptedMinOutput,
        bytes calldata /*hookData*/
    ) external {
        require(
            Common.isInitialized(encryptedAmount),
            "Encrypted amount not initialized"
        );
        require(
            Common.isInitialized(encryptedMinOutput),
            "Encrypted min output not initialized"
        );

        bytes32 orderHash = keccak256(
            abi.encode(msg.sender, key, encryptedAmount)
        );
        PoolId poolId = key.toId();

        encryptedOrders[poolId][orderHash] = encryptedAmount;
        encryptedMinOutputs[poolId][orderHash] = encryptedMinOutput;
        FHE.allowThis(encryptedOrders[poolId][orderHash]);
        FHE.allowThis(encryptedMinOutputs[poolId][orderHash]);

        emit SwapSubmitted(msg.sender, orderHash, poolId);
    }

    function _beforeSwap(
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
        require(
            Common.isInitialized(encryptedAmount),
            "Encrypted amount not initialized"
        );
        require(
            Common.isInitialized(encryptedMinOutput),
            "Encrypted min output not initialized"
        );

        // Get current pool price (scaled to fit euint128)
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        uint128 scaledPrice = uint128(uint256(sqrtPriceX96) >> 32); // Scale down for euint128
        euint128 encCurrentPrice = FHE.asEuint128(scaledPrice);

        // Homomorphic check: output >= minOutput
        euint128 expectedOutput = FHE.mul(encryptedAmount, encCurrentPrice);
        ebool isValid = FHE.gte(expectedOutput, encryptedMinOutput);
        swapValidations[poolId][orderHash] = isValid;
        // request decryption of validation result
        FHE.decrypt(isValid);

        // Clear order after validation by zeroing the ciphertexts
        encryptedOrders[poolId][orderHash] = FHE.asEuint128(0);
        encryptedMinOutputs[poolId][orderHash] = FHE.asEuint128(0);

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function _afterSwap(
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

        // Store encrypted absolute output amount
        int256 amount1Signed = int256(delta.amount1());
        uint256 outputAmount = amount1Signed < 0
            ? uint256(-amount1Signed)
            : uint256(amount1Signed);
        require(
            outputAmount <= type(uint128).max,
            "Output exceeds euint128 limit"
        );
        euint128 encOutput = FHE.asEuint128(outputAmount);
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
        require(Common.isInitialized(encOutput), "No output to decrypt");
        // request decryption task
        FHE.decrypt(encOutput);
        emit OutputDecryptionRequested(orderHash, poolId);
    }

    // Step 2: Process decrypted result
    function revealOutput(PoolKey calldata key, bytes32 orderHash) external {
        PoolId poolId = key.toId();
        euint128 encOutput = encryptedOutputs[poolId][orderHash];
        require(Common.isInitialized(encOutput), "No output to reveal");
        (uint128 outputAmount, bool isReady) = FHE.getDecryptResultSafe(
            encOutput
        );
        require(isReady, "Output not yet decrypted");
        require(outputAmount > 0, "No output available");

        encryptedOutputs[poolId][orderHash] = FHE.asEuint128(0);
        emit OutputRevealed(orderHash, poolId, outputAmount);
        // Transfer logic (e.g., FHERC20) can be added here
    }

    // Validate swap result (called separately to check homomorphic validation)
    function validateSwap(PoolKey calldata key, bytes32 orderHash) external {
        PoolId poolId = key.toId();
        ebool isValid = swapValidations[poolId][orderHash];
        require(Common.isInitialized(isValid), "Validation not initialized");
        (bool result, bool isReady) = FHE.getDecryptResultSafe(isValid);
        require(isReady, "Validation not yet decrypted");
        require(result, "Swap validation failed");
        // clear validation flag
        swapValidations[poolId][orderHash] = FHE.asEbool(false);
    }
}

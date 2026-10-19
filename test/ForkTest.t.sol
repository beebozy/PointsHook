// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {PointsHook} from "../src/PointsHook.sol";

/// Shared tests. Subclasses decide WHICH PoolManager the hook is tested against.
abstract contract PointsHookIntegrationBase is Test, ERC1155TokenReceiver {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liquidityRouter;
    PointsHook hook;
    MockERC20 token;
    PoolKey key;
    address alice = makeAddr("alice");

    /// The PoolManager to test against: the real one on a fork, or a fresh one locally.
    function _poolManager() internal virtual returns (IPoolManager);

    // Routers refund unused ETH to the caller, so the test contract must accept ETH.
    receive() external payable {}

    function setUp() public virtual {
        manager = _poolManager();
        vm.deal(address(this), 1_000 ether);

        // Test-only routers, deployed on top of whichever PoolManager we are using.
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        // Mine a salt so the hook address encodes AFTER_SWAP, then deploy with CREATE2.
        // In a test the deployer is this contract. In a deploy script it is the CREATE2 deployer.
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PointsHook).creationCode, abi.encode(manager));
        hook = new PointsHook{salt: salt}(manager);
        require(address(hook) == expected, "hook address mismatch");

        token = new MockERC20("Test Token", "TEST", 18);
        token.mint(address(this), 1_000_000 ether);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);

        // A brand new ETH/TOKEN pool: new token + new hook address = a pool that cannot already exist.
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        liquidityRouter.modifyLiquidity{value: 100 ether}(
            key, ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1_000 ether, salt: 0}), ""
        );
    }

    // ---------------------------------------------------------------- helpers

    function _id() internal view returns (uint256) {
        return uint256(PoolId.unwrap(key.toId()));
    }

    function _points(address who) internal view returns (uint256) {
        return hook.balanceOf(who, _id());
    }

    function _buy(uint256 ethIn, bytes memory hookData) internal returns (BalanceDelta) {
        return swapRouter.swap{value: ethIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _sell(uint256 tokenIn, bytes memory hookData) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(tokenIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    // ---------------------------------------------------------------- environment

    function test_hookIsWiredToThisPoolManager() public view {
        assertGt(address(manager).code.length, 0, "no PoolManager code at this address on this chain");
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, uint160(Hooks.AFTER_SWAP_FLAG));
    }

    function test_onlyThePoolManagerCanCallTheHook() public {
        vm.expectRevert();
        hook.afterSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            BalanceDelta.wrap(0),
            abi.encode(address(this))
        );
    }

    // ---------------------------------------------------------------- deltas

    function test_delta_signsOnTheRealPoolManager() public {
        BalanceDelta buy = _buy(1 ether, abi.encode(address(this)));
        assertEq(buy.amount0(), -int128(1 ether), "buy: ETH paid is negative");
        assertGt(buy.amount1(), 0, "buy: TOKEN received is positive");

        BalanceDelta sell = _sell(1 ether, abi.encode(address(this)));
        assertGt(sell.amount0(), 0, "sell: ETH received is positive");
        assertEq(sell.amount1(), -int128(1 ether), "sell: TOKEN paid is negative");
    }

    // ---------------------------------------------------------------- points

    function test_exactInput_awardsTwentyPercent_atThePoolIdAsTokenId() public {
        _buy(1 ether, abi.encode(address(this)));
        assertEq(hook.balanceOf(address(this), uint256(PoolId.unwrap(key.toId()))), 0.2 ether);
        assertEq(hook.balanceOf(address(this), _id() + 1), 0);
    }

    function test_exactOutput_awardsTwentyPercentOfEthActuallySpent() public {
        BalanceDelta delta = swapRouter.swap{value: 2 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(0.5 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this))
        );
        assertEq(delta.amount1(), int128(0.5 ether));
        assertEq(_points(address(this)), uint256(uint128(-delta.amount0())) / 5);
    }

    function testFuzz_exactInput_pointsAreEthSpentDividedByFive(uint256 amount) public {
        amount = bound(amount, 1_000, 2 ether);
        BalanceDelta delta = _buy(amount, abi.encode(address(this)));
        assertEq(uint256(uint128(-delta.amount0())), amount);
        assertEq(_points(address(this)), amount / 5);
    }

    function test_pointsAccumulate_andAreTransferable() public {
        _buy(1 ether, abi.encode(address(this)));
        _buy(2 ether, abi.encode(address(this)));
        assertEq(_points(address(this)), 0.6 ether);

        hook.safeTransferFrom(address(this), alice, _id(), 0.1 ether, "");
        assertEq(_points(alice), 0.1 ether);
        assertEq(_points(address(this)), 0.5 ether);
    }

    function test_pointsGoToTheAddressInHookData() public {
        _buy(1 ether, abi.encode(alice));
        assertEq(_points(alice), 0.2 ether);
        assertEq(_points(address(this)), 0);
    }

    // ---------------------------------------------------------------- nothing awarded

    function test_sellingTokenForEth_awardsNothing() public {
        _sell(1 ether, abi.encode(address(this)));
        assertEq(_points(address(this)), 0);
    }

    function test_hookDataThatIsTooShort_orZeroAddress_awardsNothingAndDoesNotRevert() public {
        _buy(1 ether, "");
        _buy(1 ether, abi.encodePacked(address(this))); // 20 bytes
        _buy(1 ether, abi.encode(address(0)));
        assertEq(_points(address(this)), 0);
    }
}

/// Runs the tests above against the REAL PoolManager on a forked chain.
///
///   FORK_RPC_URL=<rpc> forge test --match-contract PointsHookForkTest -vv
///
/// Optional: POOL_MANAGER=<address> (required on chains other than Ethereum and Base),
///           FORK_BLOCK=<number> to pin the block.
/// Without FORK_RPC_URL these tests are skipped, so CI without an RPC stays green.
contract PointsHookForkTest is PointsHookIntegrationBase {
    function _poolManager() internal override returns (IPoolManager) {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }

        uint256 pinned = vm.envOr("FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);

        address pm = vm.envOr("POOL_MANAGER", address(0));
        if (pm == address(0)) {
            // Confirm any address you add here against the Uniswap v4 deployments page.
            if (block.chainid == 1) pm = 0x000000000004444c5dc75cB358380D2e3dE08A90;
            else if (block.chainid == 8453) pm = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
            else revert("set POOL_MANAGER for this chain");
        }
        return IPoolManager(pm);
    }
}

/// Same tests against a freshly deployed local PoolManager. Needs no RPC, so you can check
/// that the test logic itself is right before pointing it at a fork.
contract PointsHookLocalTest is PointsHookIntegrationBase {
    function _poolManager() internal override returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(this))));
    }
}

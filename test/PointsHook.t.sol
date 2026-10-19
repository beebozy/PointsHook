// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC1155, ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {PointsHook} from "../src/PointsHook.sol";

/// Has no ERC-1155 receiver callbacks, so an ERC-1155 mint to it reverts.
contract NoReceiver {}

contract TestPointsHook is Test, Deployers, ERC1155TokenReceiver {
    MockERC20 token; // our token to use in the ETH-TOKEN pool

    // Native tokens are represented by address(0)
    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    PointsHook hook;

    address alice = makeAddr("alice");

    function setUp() public {
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        deployCodeTo("PointsHook.sol", abi.encode(manager), address(flags));
        hook = PointsHook(address(flags));

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key,) = initPool(ethCurrency, tokenCurrency, hook, 3000, SQRT_PRICE_1_1);

        // Add liquidity. 10 ETH (instead of 0.003) so swaps of 1-2 ETH stay inside the range.
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);
        uint256 ethToAdd = 10 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_1, sqrtPriceAtTickUpper, ethToAdd);

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int256(uint256(liquidityDelta)), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // ---------------------------------------------------------------- helpers

    /// ERC-1155 token id used for points: the pool id as a uint256.
    function _id(PoolKey memory k) internal pure returns (uint256) {
        return uint256(PoolId.unwrap(k.toId()));
    }

    function _points(address who) internal view returns (uint256) {
        return hook.balanceOf(who, _id(key));
    }

    function _buy(uint256 ethIn, bytes memory hookData) internal returns (BalanceDelta) {
        return swapNativeInput(key, true, -int256(ethIn), hookData, ethIn);
    }

    // ---------------------------------------------------------------- setup

    function test_hookAddressHasOnlyTheAfterSwapFlag() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, uint160(Hooks.AFTER_SWAP_FLAG));
        assertTrue(hook.getHookPermissions().afterSwap);
    }

    // ---------------------------------------------------------------- delta signs

    /// v4 deltas are from the swapper's side: negative = the swapper pays, positive = receives.
    function test_delta_buyingTokenWithEth() public {
        BalanceDelta delta = _buy(1 ether, abi.encode(address(this)));
        assertLt(delta.amount0(), 0, "ETH paid is negative");
        assertGt(delta.amount1(), 0, "TOKEN received is positive");
        assertEq(delta.amount0(), -int128(1 ether), "exact input spends exactly 1 ETH");
    }

    function test_delta_sellingTokenForEth() public {
        BalanceDelta delta = swap(key, false, -int256(1 ether), abi.encode(address(this)));
        assertGt(delta.amount0(), 0, "ETH received is positive");
        assertLt(delta.amount1(), 0, "TOKEN paid is negative");
    }

    function test_delta_exactOutput_ethSpentIsMinusAmount0() public {
        // Ask for exactly 0.5 TOKEN out. The ETH spent has to come from the delta.
        BalanceDelta delta = swapNativeInput(key, true, int256(0.5 ether), abi.encode(address(this)), 2 ether);
        assertEq(delta.amount1(), int128(0.5 ether));
        assertLt(delta.amount0(), 0);
        assertGt(uint256(uint128(-delta.amount0())), 0.5 ether, "price ~1:1 plus the 0.3% fee");
    }

    // ---------------------------------------------------------------- points id

    function test_pointsId_isThePoolIdAsUint() public {
        uint256 id = _id(key);
        assertEq(id, uint256(PoolId.unwrap(key.toId())));
        assertGt(id, 0);

        _buy(1 ether, abi.encode(address(this)));

        assertEq(hook.balanceOf(address(this), id), 0.2 ether, "points live at the pool id");
        assertEq(hook.balanceOf(address(this), id + 1), 0, "no points at any other id");
        assertEq(hook.balanceOf(alice, id), 0, "nobody else got points");
    }

    function test_pointsId_isDifferentPerPool() public {
        _buy(1 ether, abi.encode(address(this)));

        (Currency c0, Currency c1) = deployMintAndApprove2Currencies();
        (PoolKey memory key2,) = initPoolAndAddLiquidity(c0, c1, hook, 3000, SQRT_PRICE_1_1);

        assertTrue(_id(key2) != _id(key));
        assertEq(hook.balanceOf(address(this), _id(key2)), 0);
        assertEq(_points(address(this)), 0.2 ether);
    }

    function test_exactInput_awardsTwentyPercentOfEthSpent() public {
        _buy(1 ether, abi.encode(address(this)));
        assertEq(_points(address(this)), 0.2 ether);
    }

    function test_exactOutput_awardsTwentyPercentOfEthSpent() public {
        BalanceDelta delta = swapNativeInput(key, true, int256(0.5 ether), abi.encode(address(this)), 2 ether);
        uint256 ethSpent = uint256(uint128(-delta.amount0()));
        assertEq(_points(address(this)), ethSpent / 5);
    }

    function testFuzz_exactInput_pointsAreEthSpentDividedByFive(uint256 amount) public {
        amount = bound(amount, 1_000, 2 ether);
        BalanceDelta delta = _buy(amount, abi.encode(address(this)));
        assertEq(uint256(uint128(-delta.amount0())), amount);
        assertEq(_points(address(this)), amount / 5);
    }

    function test_pointsAccumulateAcrossSwaps() public {
        _buy(1 ether, abi.encode(address(this)));
        _buy(2 ether, abi.encode(address(this)));
        assertEq(_points(address(this)), 0.6 ether);
    }

    function test_pointsGoToTheAddressInHookData_notTheCaller() public {
        // alice is an EOA, so the ERC-1155 mint needs no receiver callback.
        _buy(1 ether, abi.encode(alice));
        assertEq(_points(alice), 0.2 ether);
        assertEq(_points(address(this)), 0);
    }

    function test_mintEmitsTransferSingle() public {
        // The pool manager calls the hook, so it is the ERC-1155 "operator".
        vm.expectEmit(true, true, true, true, address(hook));
        emit ERC1155.TransferSingle(address(manager), address(0), address(this), _id(key), 0.2 ether);
        _buy(1 ether, abi.encode(address(this)));
    }

    function test_pointsAreTransferable() public {
        _buy(1 ether, abi.encode(address(this)));
        hook.safeTransferFrom(address(this), alice, _id(key), 0.05 ether, "");
        assertEq(_points(address(this)), 0.15 ether);
        assertEq(_points(alice), 0.05 ether);
    }

    // ---------------------------------------------------------------- cases that award nothing

    function test_sellingTokenForEth_awardsNothing() public {
        swap(key, false, -int256(1 ether), abi.encode(address(this)));
        assertEq(_points(address(this)), 0);
    }

    function test_nonEthPool_awardsNothing() public {
        (Currency c0, Currency c1) = deployMintAndApprove2Currencies();
        (PoolKey memory key2,) = initPoolAndAddLiquidity(c0, c1, hook, 3000, SQRT_PRICE_1_1);
        swap(key2, true, -int256(1 ether), abi.encode(address(this)));
        assertEq(hook.balanceOf(address(this), _id(key2)), 0);
    }

    function test_dustSwap_mintsZeroAndDoesNotRevert() public {
        // 4 wei / 5 rounds down to 0 points.
        _buy(4, abi.encode(address(this)));
        assertEq(_points(address(this)), 0);
    }

    // ---------------------------------------------------------------- hookData

    function test_emptyHookData_awardsNothing() public {
        _buy(1 ether, "");
        assertEq(_points(address(this)), 0);
    }

    function test_hookDataShorterThan32Bytes_awardsNothing_andDoesNotRevert() public {
        _buy(1 ether, abi.encodePacked(address(this))); // 20 bytes
        _buy(1 ether, hex"01"); // 1 byte
        assertEq(_points(address(this)), 0);
    }

    function test_zeroAddressHookData_awardsNothing() public {
        _buy(1 ether, abi.encode(address(0)));
        assertEq(_points(address(0)), 0);
    }

    function test_hookDataWithTrailingBytes_stillWorks() public {
        _buy(1 ether, abi.encodePacked(abi.encode(address(this)), hex"deadbeef"));
        assertEq(_points(address(this)), 0.2 ether);
    }

    /// Still reverts: a 32-byte word with bits above the low 160 is not a valid address, and
    /// abi.decode rejects it. Add a range check (raw > type(uint160).max) to make this a no-op.
    function test_hookDataWithDirtyUpperBits_revertsTheSwap() public {
        vm.expectRevert();
        _buy(1 ether, abi.encode(uint256(type(uint160).max) + 1));
    }

    // ---------------------------------------------------------------- recipients (ERC-1155 callbacks)

    function test_contractRecipientWithReceiver_works() public {
        // This test contract inherits ERC1155TokenReceiver, so it can receive points.
        _buy(1 ether, abi.encode(address(this)));
        assertEq(_points(address(this)), 0.2 ether);
    }

    /// A contract that cannot receive ERC-1155 tokens blocks the whole swap.
    function test_contractRecipientWithoutReceiver_revertsTheSwap() public {
        address recipient = address(new NoReceiver());
        vm.expectRevert();
        _buy(1 ether, abi.encode(recipient));
    }

    function test_swap() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(address(this), poolIdUint);

        // Set user address in hook data
        bytes memory hookData = abi.encode(address(this));

        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        uint256 pointsBalanceAfterSwap = hook.balanceOf(address(this), poolIdUint);
        assertEq(pointsBalanceAfterSwap - pointsBalanceOriginal, 2 * 10 ** 14);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ArcadeV4SwapRouter} from "../v4src/ArcadeV4SwapRouter.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Duck-typed PoolManager mock. Configurable swap delta so tests can
///         exercise the router's settle / take paths against known numbers.
contract MockPoolManagerV4 {
    BalanceDelta public nextSwapDelta;
    Currency public lastSync;
    address public lastTakeTo;
    Currency public lastTakeCurrency;
    uint256 public lastTakeAmount;
    bool public swapCalled;

    // Track currency balances the mock claims to hold for callers.
    mapping(address => mapping(address => uint256)) internal credits;

    function setNextSwapDelta(int128 a0, int128 a1) external {
        nextSwapDelta = toBalanceDelta(a0, a1);
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory, SwapParams memory, bytes calldata)
        external
        returns (BalanceDelta)
    {
        swapCalled = true;
        return nextSwapDelta;
    }

    function sync(Currency c) external {
        lastSync = c;
    }

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(Currency c, address to, uint256 amount) external {
        lastTakeCurrency = c;
        lastTakeTo = to;
        lastTakeAmount = amount;
        // The mock doesn't hold real reserves; the test sets up the output
        // token to be mintable so the recipient sees the right balance.
        MockERC20(Currency.unwrap(c)).mint(to, amount);
    }
}

contract ArcadeV4SwapRouterTest is Test {
    MockPoolManagerV4 pm;
    MockERC20 usdc;
    MockERC20 token;
    ArcadeV4SwapRouter router;

    address constant USER = address(0xA11CE);
    address constant RECIPIENT = address(0xBEEF);

    PoolKey internal key;
    bool internal usdcIsCurrency0;

    function setUp() public {
        pm = new MockPoolManagerV4();
        usdc = new MockERC20("USDC", "USDC");
        token = new MockERC20("Arcade", "ARC");
        router = new ArcadeV4SwapRouter(IPoolManager(address(pm)));

        // Canonical PoolKey sort.
        usdcIsCurrency0 = address(usdc) < address(token);
        (address c0, address c1) =
            usdcIsCurrency0 ? (address(usdc), address(token)) : (address(token), address(usdc));
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });

        // Fund + approve.
        usdc.mint(USER, 1_000_000e6);
        token.mint(USER, 1_000_000e18);
        vm.prank(USER);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(USER);
        token.approve(address(router), type(uint256).max);
    }

    // --- exact-input -----------------------------------------------------

    function test_exactInputSingle_buyMovesUsdcInTokenOut() public {
        // USER buys TOKEN with 1_000 USDC, expects 50e18 TOKEN out per mock.
        // Mock swap result: from the swap's perspective, pool RECEIVED USDC
        // (delta on USDC slot = -1_000e6) and PAID TOKEN (delta on TOKEN
        // slot = +50e18).
        bool zeroForOne = usdcIsCurrency0; // BUY = USDC -> TOKEN
        if (zeroForOne) {
            pm.setNextSwapDelta(int128(-int256(1_000e6)), int128(50e18));
        } else {
            pm.setNextSwapDelta(int128(50e18), int128(-int256(1_000e6)));
        }

        uint256 userUsdcBefore = usdc.balanceOf(USER);
        uint256 recipTokenBefore = token.balanceOf(RECIPIENT);

        vm.prank(USER);
        uint256 amountOut = router.exactInputSingle(
            key, zeroForOne, 1_000e6, 1e18, RECIPIENT, 0
        );

        assertEq(amountOut, 50e18, "amountOut");
        assertEq(token.balanceOf(RECIPIENT) - recipTokenBefore, 50e18, "recipient got tokens");
        assertEq(userUsdcBefore - usdc.balanceOf(USER), 1_000e6, "user paid usdc");
        assertTrue(pm.swapCalled());
        assertEq(Currency.unwrap(pm.lastSync()), address(usdc), "synced input currency");
        assertEq(Currency.unwrap(pm.lastTakeCurrency()), address(token), "took output currency");
        assertEq(pm.lastTakeTo(), RECIPIENT);
    }

    function test_exactInputSingle_revertsOnSlippage() public {
        bool zeroForOne = usdcIsCurrency0;
        if (zeroForOne) {
            pm.setNextSwapDelta(int128(-int256(1_000e6)), int128(50e18));
        } else {
            pm.setNextSwapDelta(int128(50e18), int128(-int256(1_000e6)));
        }
        // minAmountOut = 100e18, mock returns 50e18 → revert.
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(ArcadeV4SwapRouter.SlippageExceeded.selector, 50e18, 100e18)
        );
        router.exactInputSingle(key, zeroForOne, 1_000e6, 100e18, RECIPIENT, 0);
    }

    function test_exactInputSingle_zeroAmountReverts() public {
        vm.prank(USER);
        vm.expectRevert(ArcadeV4SwapRouter.ZeroAmount.selector);
        router.exactInputSingle(key, usdcIsCurrency0, 0, 0, RECIPIENT, 0);
    }

    // --- exact-output ----------------------------------------------------

    function test_exactOutputSingle_buyComputesInputFromOutput() public {
        // USER wants exactly 50e18 TOKEN, mock quotes 1_000e6 USDC input.
        bool zeroForOne = usdcIsCurrency0;
        if (zeroForOne) {
            pm.setNextSwapDelta(int128(-int256(1_000e6)), int128(50e18));
        } else {
            pm.setNextSwapDelta(int128(50e18), int128(-int256(1_000e6)));
        }
        uint256 userUsdcBefore = usdc.balanceOf(USER);

        vm.prank(USER);
        uint256 amountIn = router.exactOutputSingle(
            key, zeroForOne, 50e18, 2_000e6, RECIPIENT, 0
        );

        assertEq(amountIn, 1_000e6, "amountIn");
        assertEq(token.balanceOf(RECIPIENT), 50e18);
        assertEq(userUsdcBefore - usdc.balanceOf(USER), 1_000e6);
    }

    function test_exactOutputSingle_revertsOnSlippage() public {
        bool zeroForOne = usdcIsCurrency0;
        if (zeroForOne) {
            pm.setNextSwapDelta(int128(-int256(1_000e6)), int128(50e18));
        } else {
            pm.setNextSwapDelta(int128(50e18), int128(-int256(1_000e6)));
        }
        // Cap maxAmountIn at 500e6 USDC, mock requires 1_000e6 → revert.
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(ArcadeV4SwapRouter.SlippageExceeded.selector, 1_000e6, 500e6)
        );
        router.exactOutputSingle(key, zeroForOne, 50e18, 500e6, RECIPIENT, 0);
    }

    // --- direction (sell) ------------------------------------------------

    function test_exactInputSingle_sellMovesTokenInUsdcOut() public {
        // SELL = TOKEN -> USDC. zeroForOne flips depending on sort.
        bool zeroForOne = !usdcIsCurrency0;
        // Pool received TOKEN (input), paid USDC (output).
        if (zeroForOne) {
            // currency0=TOKEN, currency1=USDC, zeroForOne=true → input=token0
            pm.setNextSwapDelta(int128(-int256(10e18)), int128(200e6));
        } else {
            // currency0=USDC, currency1=TOKEN, zeroForOne=false → input=token1
            pm.setNextSwapDelta(int128(200e6), int128(-int256(10e18)));
        }
        uint256 userTokenBefore = token.balanceOf(USER);

        vm.prank(USER);
        uint256 amountOut = router.exactInputSingle(
            key, zeroForOne, 10e18, 1e6, RECIPIENT, 0
        );

        assertEq(amountOut, 200e6, "got 200 USDC");
        assertEq(usdc.balanceOf(RECIPIENT), 200e6);
        assertEq(userTokenBefore - token.balanceOf(USER), 10e18, "user paid token");
    }

    // --- access control --------------------------------------------------

    // -----------------------------------------------------------------
    // Referral surcharge
    // -----------------------------------------------------------------

    function _setBuyDelta() internal returns (bool zeroForOne) {
        zeroForOne = usdcIsCurrency0; // BUY = USDC -> TOKEN
        if (zeroForOne) {
            pm.setNextSwapDelta(int128(-int256(1_000e6)), int128(50e18));
        } else {
            pm.setNextSwapDelta(int128(50e18), int128(-int256(1_000e6)));
        }
    }

    // The router's per-swap "referral surcharge" was REMOVED (referral is now a
    // share of the platform fee, not a surcharge on top), so its owner/rate/
    // *Referred tests are gone with it. The plain swap + slippage tests above
    // still cover the router's whole surface.

    function test_unlockCallback_onlyPoolManager() public {
        ArcadeV4SwapRouter.SwapCallbackData memory cb = ArcadeV4SwapRouter.SwapCallbackData({
            payer: USER,
            recipient: RECIPIENT,
            key: key,
            zeroForOne: true,
            amountSpecified: -int256(1_000e6),
            sqrtPriceLimitX96: 0
        });
        vm.expectRevert(ArcadeV4SwapRouter.NotPoolManager.selector);
        router.unlockCallback(abi.encode(cb));
    }
}

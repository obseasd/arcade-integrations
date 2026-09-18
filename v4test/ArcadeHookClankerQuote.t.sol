// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ArcadeHook} from "../v4src/ArcadeHook.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";

/**
 * @title ArcadeHookClankerQuoteTest
 * @notice The owner-selected pair asset for CLANKER launches.
 *
 *         The feature exists so a platform token can become the default pair for
 *         new Clanker launches WITHOUT changing `createLaunch`. Every caller -
 *         the web launcher, the agent API, the tweet-launch cron - keeps passing
 *         the arguments it always did and picks up the new pair automatically.
 *         These tests pin that property, and the three that would hurt if they
 *         regressed: PUMP must never follow the quote, an existing launch must
 *         never be repaired by a later flip, and the atomic dev-buy must pull the
 *         PAIR asset rather than USDC.
 */
contract ArcadeHookClankerQuoteTest is Test {
    ArcadeHook hook;
    PoolManager pm;
    TestERC20 usdc;
    TestERC20 arcade;

    address poolManagerAddr;
    address constant LOCKED_VAULT = address(0xCAFE);
    address constant TREASURY = address(0xBEEF);
    address constant ESCROW = address(0xE5C);
    address constant OWNER = address(0x0123);
    address constant ALICE = address(0xA11CE);

    uint160 internal constant TARGET_FLAGS = uint160(0x3ECE);

    // An 18-decimal platform token, i.e. NOT the 6-decimal shape the USDC
    // constants assume. That difference is the whole reason the bounds are
    // owner-supplied instead of derived.
    uint256 constant ARC_DEFAULT_MCAP = 35_000e18;
    uint256 constant ARC_MIN_MCAP = 1_000e18;
    uint256 constant ARC_MAX_MCAP = 10_000_000e18;

    function setUp() public {
        pm = new PoolManager(address(this));
        poolManagerAddr = address(pm);
        usdc = new TestERC20(0);
        arcade = new TestERC20(0);

        address hookAddr = address(uint160(0xCAFE0000 | TARGET_FLAGS));
        deployCodeTo(
            "ArcadeHook.sol:ArcadeHook",
            abi.encode(
                IPoolManager(poolManagerAddr),
                Currency.wrap(address(usdc)),
                LOCKED_VAULT,
                TREASURY,
                ESCROW,
                OWNER
            ),
            hookAddr
        );
        hook = ArcadeHook(hookAddr);
    }

    /// Configures the quote AND makes it the protocol default, which is the
    /// state a tweet launch would inherit.
    function _setQuote(address q) internal {
        vm.prank(OWNER);
        hook.setClankerQuote(q, ARC_DEFAULT_MCAP, ARC_MIN_MCAP, ARC_MAX_MCAP, true);
    }

    /// Funds ALICE with both assets and approves the hook for each.
    function _fundAlice() internal {
        usdc.mint(ALICE, 1_000e6);
        arcade.mint(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        usdc.approve(address(hook), type(uint256).max);
        arcade.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /* ---------------------------- the default ---------------------------- */

    /// Shipped state: no quote, so nothing changes for anyone.
    function test_defaultsToUsdc() public view {
        assertEq(hook.clankerQuote(), address(0), "ships unset");
        assertEq(hook.clankerQuoteDefaultMcap(), 0, "no default mcap");
    }

    /* ------------------------------ the setter ---------------------------- */

    function test_setter_isOwnerOnly() public {
        vm.prank(ALICE);
        vm.expectRevert();
        hook.setClankerQuote(address(arcade), ARC_DEFAULT_MCAP, ARC_MIN_MCAP, ARC_MAX_MCAP, true);
    }

    /// USDC has one encoding here: the zero address. Accepting the literal USDC
    /// address too would give the same state two spellings.
    function test_setter_rejectsUsdcAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(ArcadeHook.QuoteNotAllowed.selector);
        hook.setClankerQuote(address(usdc), ARC_DEFAULT_MCAP, ARC_MIN_MCAP, ARC_MAX_MCAP, true);
    }

    /// An EOA would give every pool a pair that cannot transfer.
    function test_setter_rejectsEoa() public {
        vm.prank(OWNER);
        vm.expectRevert(ArcadeHook.QuoteNotAllowed.selector);
        hook.setClankerQuote(ALICE, ARC_DEFAULT_MCAP, ARC_MIN_MCAP, ARC_MAX_MCAP, true);
    }

    /// Same guard the RWA path uses: one of our own launches as the pair would
    /// make the anti-sniper side-resolution misfire.
    function test_setter_rejectsOneOfOurLaunches() public {
        _fundAlice();
        vm.prank(ALICE);
        (address tok,) = hook.createLaunch("Demo", "DEMO", "ipfs://d", 0, address(0), 0, 0, 0, 0, "", 0, 0, 0);

        vm.prank(OWNER);
        vm.expectRevert(ArcadeHook.QuoteNotAllowed.selector);
        hook.setClankerQuote(tok, ARC_DEFAULT_MCAP, ARC_MIN_MCAP, ARC_MAX_MCAP, true);
    }

    /// The bounds are the one thing with no on-chain sanity check available -
    /// there is no oracle here - so the ordering is enforced instead.
    function test_setter_rejectsUnorderedBounds() public {
        vm.startPrank(OWNER);
        vm.expectRevert(ArcadeHook.InvalidStartMcap.selector);
        hook.setClankerQuote(address(arcade), ARC_DEFAULT_MCAP, 0, ARC_MAX_MCAP, true); // min == 0
        vm.expectRevert(ArcadeHook.InvalidStartMcap.selector);
        hook.setClankerQuote(address(arcade), ARC_MIN_MCAP - 1, ARC_MIN_MCAP, ARC_MAX_MCAP, true); // default < min
        vm.expectRevert(ArcadeHook.InvalidStartMcap.selector);
        hook.setClankerQuote(address(arcade), ARC_DEFAULT_MCAP, ARC_MIN_MCAP, ARC_DEFAULT_MCAP - 1, true); // max < default
        vm.stopPrank();
    }

    function test_setter_clearsBackToUsdc() public {
        _setQuote(address(arcade));
        assertEq(hook.clankerQuote(), address(arcade), "set");

        vm.prank(OWNER);
        hook.setClankerQuote(address(0), 0, 0, 0, false);
        assertEq(hook.clankerQuote(), address(0), "cleared");
        assertEq(hook.clankerQuoteDefaultMcap(), 0, "bounds cleared too");
    }

    /* ----------------------------- the effect ----------------------------- */

    /// The point of the feature: a Clanker launch pairs against the quote with
    /// the caller passing exactly what it always passed.
    function test_clankerPairsAgainstQuote_withNoCallerChange() public {
        _fundAlice();
        _setQuote(address(arcade));

        vm.prank(ALICE);
        (address tok,) = hook.createLaunch("Clk", "CLK", "ipfs://d", 1, address(0), 0, 0, 0, 1, "", 0, 0, 0);

        // The pool's pair is recorded on the launch, which is what every later
        // read (swap validation, fee side, dev-buy) resolves through.
        assertEq(hook.quoteAssetOf(tok), address(arcade), "launch paired against the quote");
    }

    /// PUMP must never follow the quote: its curve is denominated in 6-decimal
    /// USDC by hard constants, so a different pair would silently misprice it.
    function test_pumpStaysOnUsdc_evenWithQuoteSet() public {
        _fundAlice();
        _setQuote(address(arcade));

        vm.prank(ALICE);
        (address tok,) = hook.createLaunch("Pmp", "PMP", "ipfs://d", 0, address(0), 0, 0, 0, 0, "", 0, 0, 0);

        assertEq(hook.quoteAssetOf(tok), address(0), "pump ignored the quote");
    }

    /// A pool's pair is fixed at creation. Flipping the quote afterwards must not
    /// reach back and change what an existing launch trades against.
    function test_existingLaunchIsUnaffectedByALaterFlip() public {
        _fundAlice();

        vm.prank(ALICE);
        (address tok,) = hook.createLaunch("Clk", "CLK", "ipfs://d", 1, address(0), 0, 0, 0, 1, "", 0, 0, 0);
        assertEq(hook.quoteAssetOf(tok), address(0), "opened against USDC");

        _setQuote(address(arcade));
        assertEq(hook.quoteAssetOf(tok), address(0), "still USDC after the flip");
    }

    /// The dev-buy has to pull the PAIR asset. Pulling USDC into an
    /// ARCADE-paired pool would settle the wrong side.
    function test_devBuyPullsTheQuoteNotUsdc() public {
        _fundAlice();
        _setQuote(address(arcade));

        uint256 buy = 10e18;
        uint256 usdcBefore = usdc.balanceOf(ALICE);
        uint256 arcBefore = arcade.balanceOf(ALICE);

        vm.prank(ALICE);
        hook.createLaunch("Clk", "CLK", "ipfs://d", 1, address(0), 0, 0, 0, 1, "", 0, buy, 0);

        // Only the flat 3 USDC creation fee leaves the USDC balance; the buy
        // itself comes out of the pair asset.
        assertEq(usdcBefore - usdc.balanceOf(ALICE), 3e6, "USDC moved only for the creation fee");
        assertEq(arcBefore - arcade.balanceOf(ALICE), buy, "the dev buy was paid in the pair asset");
    }

    /// Bounds are read in the quote's units once a quote is set, so a value that
    /// would be valid as 6-decimal USDC is rejected as 18-decimal ARCADE.
    function test_startMcapBoundsAreReadInQuoteUnits() public {
        _fundAlice();
        _setQuote(address(arcade));

        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.InvalidStartMcap.selector);
        hook.createLaunch("Clk", "CLK", "ipfs://d", 1, address(0), 0, 0, 0, 1, "", 35_000e6, 0, 0);
    }

    /* --------------------- the per-launch choice ------------------------- */

    /// Configures the quote WITHOUT making it the default, which is the state
    /// the protocol ships in once an Arcade token exists but is opt-in.
    function _setQuoteNotDefault(address q) internal {
        vm.prank(OWNER);
        hook.setClankerQuote(q, ARC_DEFAULT_MCAP, ARC_MIN_MCAP, ARC_MAX_MCAP, false);
    }

    /// Configured but not default: a launch that says nothing still gets USDC.
    function test_configuredButNotDefault_staysUsdc() public {
        _fundAlice();
        _setQuoteNotDefault(address(arcade));

        vm.prank(ALICE);
        (address tok,) = hook.createLaunch("Clk", "CLK", "ipfs://d", 1, address(0), 0, 0, 0, 1, "", 0, 0, 0);
        assertEq(hook.quoteAssetOf(tok), address(0), "no preference means USDC while opt-in");
    }

    /// A creator opts IN from the UI even though the default is still USDC.
    function test_selector_forcesQuote_againstAUsdcDefault() public {
        _fundAlice();
        _setQuoteNotDefault(address(arcade));

        vm.prank(ALICE);
        (address tok,) =
            hook.createLaunch("Clk", "CLK", "ipfs://d", 1, address(0), 0, 0, 0, 1, "", 0, 0, 2);
        assertEq(hook.quoteAssetOf(tok), address(arcade), "creator chose the quote");
    }

    /// And opts OUT even though the default is the quote.
    function test_selector_forcesUsdc_againstAQuoteDefault() public {
        _fundAlice();
        _setQuote(address(arcade)); // default = arcade

        vm.prank(ALICE);
        (address tok,) =
            hook.createLaunch("Clk", "CLK", "ipfs://d", 1, address(0), 0, 0, 0, 1, "", 0, 0, 1);
        assertEq(hook.quoteAssetOf(tok), address(0), "creator chose USDC");
    }

    /// Asking for a pair the protocol has not configured REVERTS. Silently
    /// handing back USDC would give a creator a different pool than the one
    /// they asked for, with nothing to tell them.
    function test_selector_forceQuote_revertsWhenNoneConfigured() public {
        _fundAlice();
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.QuoteNotAllowed.selector);
        hook.createLaunch("Clk", "CLK", "ipfs://d", 1, address(0), 0, 0, 0, 1, "", 0, 0, 2);
    }

    function test_selector_rejectsUnknownValue() public {
        _fundAlice();
        _setQuote(address(arcade));
        vm.prank(ALICE);
        vm.expectRevert(ArcadeHook.QuoteNotAllowed.selector);
        hook.createLaunch("Clk", "CLK", "ipfs://d", 1, address(0), 0, 0, 0, 1, "", 0, 0, 3);
    }

    /// The one-call switch the tweet-launch path follows.
    function test_setDefaultFlag_flipsWhatANoPreferenceLaunchGets() public {
        _fundAlice();
        _setQuoteNotDefault(address(arcade));

        vm.prank(OWNER);
        hook.setClankerQuoteIsDefault(true);

        vm.prank(ALICE);
        (address tok,) = hook.createLaunch("Clk", "CLK", "ipfs://d", 1, address(0), 0, 0, 0, 1, "", 0, 0, 0);
        assertEq(hook.quoteAssetOf(tok), address(arcade), "tweet-shaped launch followed the new default");
    }

    /// Cannot make "default" point at nothing.
    function test_setDefaultFlag_requiresAConfiguredQuote() public {
        vm.prank(OWNER);
        vm.expectRevert(ArcadeHook.QuoteNotAllowed.selector);
        hook.setClankerQuoteIsDefault(true);
    }

    /// Clearing the asset must clear the default with it.
    function test_clearing_alsoClearsTheDefaultFlag() public {
        _setQuote(address(arcade));
        assertTrue(hook.clankerQuoteIsDefault(), "default on");
        vm.prank(OWNER);
        hook.setClankerQuote(address(0), 0, 0, 0, false);
        assertFalse(hook.clankerQuoteIsDefault(), "default cleared with the asset");
    }
}

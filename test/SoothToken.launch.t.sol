// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SoothToken} from "../src/SoothToken.sol";

/// @dev Local stand-in for the launch factory. Deploys the token and performs the whole launch split in
///      one call, so every step lands in the same transaction the way `launchCustom` performs it.
contract SoothLaunchHarness {
    uint256 public supplyInConstructorTx;
    uint256 public balanceInConstructorTx;

    function deployAndSplit(bytes32 salt, address distributor, address pool, address remainder, uint256 poolBps)
        external
        returns (SoothToken token)
    {
        token = new SoothToken{salt: salt}();
        supplyInConstructorTx = token.totalSupply();
        balanceInConstructorTx = token.balanceOf(address(this));
        uint256 supply = supplyInConstructorTx;
        uint256 swarm = supply * 1_000 / 10_000;
        uint256 seeded = supply * poolBps / 10_000;
        require(token.transfer(distributor, swarm), "swarm transfer failed");
        require(token.transfer(pool, seeded), "seed transfer failed");
        require(token.transfer(remainder, token.balanceOf(address(this))), "remainder transfer failed");
    }

    function deploy(bytes32 salt) external returns (SoothToken) {
        return new SoothToken{salt: salt}();
    }
}

contract SoothTokenLaunchTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SoothToken private token;
    address private holder;
    address private other;

    function setUp() public {
        token = new SoothToken();
        holder = makeAddr("holder");
        other = makeAddr("other");
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flow, one transaction
    // ---------------------------------------------------------------------------------------------

    function test_launchInOneTransactionMovesExactShares() public {
        SoothLaunchHarness factory = new SoothLaunchHarness();
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address remainder = makeAddr("remainder");

        SoothToken launched = factory.deployAndSplit(bytes32(uint256(1)), distributor, pool, remainder, 8_000);

        assertEq(factory.supplyInConstructorTx(), SUPPLY, "supply at deployment");
        assertEq(factory.balanceInConstructorTx(), SUPPLY, "factory did not receive the whole supply");
        assertEq(launched.balanceOf(distributor), 100_000_000 ether);
        assertEq(launched.balanceOf(pool), 800_000_000 ether);
        assertEq(launched.balanceOf(remainder), 100_000_000 ether);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_launchSplitIsExactForAnyPoolShare(uint256 poolBps, bytes32 salt) public {
        poolBps = bound(poolBps, 0, 9_000);
        SoothLaunchHarness factory = new SoothLaunchHarness();
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address remainder = makeAddr("remainder");

        SoothToken launched = factory.deployAndSplit(salt, distributor, pool, remainder, poolBps);

        uint256 swarm = SUPPLY / 10;
        uint256 seeded = SUPPLY * poolBps / 10_000;
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(pool), seeded);
        assertEq(launched.balanceOf(remainder), SUPPLY - swarm - seeded);
        assertEq(launched.totalSupply(), SUPPLY);

        // Claims leave the distributor whole, to the last unit.
        vm.prank(distributor);
        assertTrue(launched.transfer(holder, swarm));
        assertEq(launched.balanceOf(holder), swarm);
        assertEq(launched.balanceOf(distributor), 0);
    }

    function test_create2RedeployAtSameSaltFails() public {
        SoothLaunchHarness factory = new SoothLaunchHarness();
        factory.deploy(bytes32(uint256(7)));
        vm.expectRevert();
        factory.deploy(bytes32(uint256(7)));
    }

    function test_mintRecipientIsImmediateCreatorNotTxOrigin() public {
        SoothLaunchHarness factory = new SoothLaunchHarness();
        address origin = makeAddr("origin");
        vm.prank(origin, origin);
        SoothToken launched = factory.deploy(bytes32(uint256(9)));
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(origin), 0);
        assertEq(launched.balanceOf(address(this)), 0);
    }

    function test_constructorRejectsNativeValue() public {
        vm.deal(address(this), 1 ether);
        bytes memory code = type(SoothToken).creationCode;
        address created;
        assembly ("memory-safe") {
            created := create(1, add(code, 32), mload(code))
        }
        assertEq(created, address(0), "a payable constructor would let value be locked in the token");
    }

    // ---------------------------------------------------------------------------------------------
    // Floor checks reproduced locally
    // ---------------------------------------------------------------------------------------------

    function test_runtimeHasNoReachableDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    function test_privilegedCallsFromDeployerNeitherMoveNorFreezeAHolder() public {
        assertTrue(token.transfer(holder, SUPPLY / 1_000));
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], holder, true));
            assertFalse(ok, signatures[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(holder, address(this), 1);

        assertEq(token.balanceOf(holder), SUPPLY / 1_000);
        vm.prank(holder);
        assertTrue(token.transfer(other, SUPPLY / 2_000));
        assertEq(token.balanceOf(other), SUPPLY / 2_000);
    }

    function test_mintLikeCallsWithLargeAmountsNeverGrowSupply() public {
        address attacker = makeAddr("attacker");
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(attacker), 0);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Adversarial fuzzing
    // ---------------------------------------------------------------------------------------------

    /// @dev Any calldata that is not one of the three state-changing ERC-20 selectors must leave every
    ///      balance and allowance untouched, whoever sends it.
    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_arbitraryCalldataCannotChangeState(address caller, bytes calldata data) public {
        if (data.length >= 4) {
            bytes4 sel = bytes4(data[:4]);
            vm.assume(
                sel != IERC20.transfer.selector && sel != IERC20.transferFrom.selector && sel != IERC20.approve.selector
            );
        }
        assertTrue(token.transfer(holder, 1_000 ether));
        assertTrue(token.approve(other, 500 ether));

        vm.recordLogs();
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        ok;
        assertEq(vm.getRecordedLogs().length, 0, "a non-transfer call emitted an event");

        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(holder), 1_000 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1_000 ether);
        assertEq(token.allowance(address(this), other), 500 ether);
        assertEq(
            token.balanceOf(caller),
            caller == address(this) ? SUPPLY - 1_000 ether : (caller == holder ? 1_000 ether : 0)
        );
    }

    /// @dev A caller with no allowance cannot move a single unit of someone else's balance.
    function testFuzz_strangerCannotPullWithoutAllowance(address stranger, uint256 amount) public {
        vm.assume(stranger != holder);
        amount = bound(amount, 1, type(uint256).max);
        assertTrue(token.transfer(holder, 10 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transferFrom(holder, stranger, amount);
        assertEq(token.balanceOf(holder), 10 ether);
    }

    /// @dev The infinite-allowance shortcut applies only to exactly type(uint256).max; one less decrements.
    function testFuzz_onlyExactMaxAllowanceIsInfinite(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        assertTrue(token.approve(other, type(uint256).max - 1));
        vm.prank(other);
        assertTrue(token.transferFrom(address(this), holder, amount));
        assertEq(token.allowance(address(this), other), type(uint256).max - 1 - amount);

        assertTrue(token.approve(other, type(uint256).max));
        vm.prank(other);
        assertTrue(token.transferFrom(address(this), holder, amount > SUPPLY - amount ? SUPPLY - amount : amount));
        assertEq(token.allowance(address(this), other), type(uint256).max);
    }

    /// @dev Transfers between two arbitrary holders preserve the pair's combined balance and the supply.
    function testFuzz_transferBetweenArbitraryHoldersConserves(address a, address b, uint256 funded, uint256 sent)
        public
    {
        vm.assume(a != address(0) && b != address(0) && a != address(this) && b != address(this));
        funded = bound(funded, 0, SUPPLY);
        sent = bound(sent, 0, funded);
        assertTrue(token.transfer(a, funded));
        uint256 pairBefore = a == b ? token.balanceOf(a) : token.balanceOf(a) + token.balanceOf(b);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(a, b, sent);
        vm.prank(a);
        assertTrue(token.transfer(b, sent));
        uint256 pairAfter = a == b ? token.balanceOf(a) : token.balanceOf(a) + token.balanceOf(b);
        assertEq(pairAfter, pairBefore);
        assertEq(token.balanceOf(a), a == b ? funded : funded - sent);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Approvals are independent per (owner, spender) pair and never touch balances.
    function testFuzz_approvalsAreIsolated(address owner, address spenderA, address spenderB, uint256 x, uint256 y)
        public
    {
        vm.assume(owner != address(0) && spenderA != address(0) && spenderB != address(0) && spenderA != spenderB);
        vm.startPrank(owner);
        assertTrue(token.approve(spenderA, x));
        assertTrue(token.approve(spenderB, y));
        vm.stopPrank();
        assertEq(token.allowance(owner, spenderA), x);
        assertEq(token.allowance(owner, spenderB), y);
        assertEq(token.allowance(spenderA, owner), owner == spenderA ? x : 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferReturnsExactlyTrueWord(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (holder, amount)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 1);
    }

    function test_transferToTokenContractIsAcceptedButUnrecoverable() public {
        // Documented behaviour: there is no rescue path, and tokens sent here still count in totalSupply.
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", address(this), 1 ether));
        assertFalse(ok);
    }

    function test_approveZeroAddressSpenderRevertsAndZeroOwnerIsUnreachable() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(other, 1);
    }

    function test_transferFromZeroAddressSenderReverts() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.transfer(other, 0);
    }

    function test_entireSupplyCanRoundTripThroughThreeHolders() public {
        assertTrue(token.transfer(holder, SUPPLY));
        vm.prank(holder);
        assertTrue(token.approve(other, SUPPLY));
        vm.prank(other);
        assertTrue(token.transferFrom(holder, address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.allowance(holder, other), 0);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, other, 0, 1));
        token.transferFrom(holder, address(this), 1);
    }
}

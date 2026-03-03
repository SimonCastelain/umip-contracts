// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/UMIPVault.sol";
import "../src/adapters/GMXAdapterMock.sol";
import "../src/adapters/VertexAdapterMock.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Mock USDC for testing
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title UMIPVault Tests
 * @notice Tests for deposit/withdraw and hub-and-spoke collateral management
 */
contract UMIPVaultTest is Test {
    UMIPVault vault;
    MockUSDC usdc;
    GMXAdapterMock gmxAdapter;
    VertexAdapterMock vertexAdapter;

    address user;
    address user2;

    uint256 constant INITIAL_BALANCE = 10000e6; // 10,000 USDC

    function setUp() public {
        // Deploy contracts
        usdc = new MockUSDC();
        vault = new UMIPVault(address(usdc));
        gmxAdapter = new GMXAdapterMock();
        vertexAdapter = new VertexAdapterMock();

        // Set adapters
        vault.setAdapters(address(gmxAdapter), address(vertexAdapter), address(0));

        // Setup users
        user = makeAddr("user");
        user2 = makeAddr("user2");

        // Mint USDC to users
        usdc.mint(user, INITIAL_BALANCE);
        usdc.mint(user2, INITIAL_BALANCE);

        // Give users ETH for execution fees
        vm.deal(user, 10 ether);
        vm.deal(user2, 10 ether);
    }

    // ============================================
    // Day 2: Deposit Tests
    // ============================================

    function test_Deposit_IncreasesIdleCollateral() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        assertEq(vault.userIdleCollateral(user), 1000e6, "Idle should be 1000");
        assertEq(vault.userTotalDeposited(user), 1000e6, "Total should be 1000");

        vm.stopPrank();
    }

    function test_Deposit_MultipleDeposits() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 2000e6);

        vault.deposit(500e6);
        assertEq(vault.userIdleCollateral(user), 500e6);

        vault.deposit(300e6);
        assertEq(vault.userIdleCollateral(user), 800e6);

        vault.deposit(200e6);
        assertEq(vault.userIdleCollateral(user), 1000e6);
        assertEq(vault.userTotalDeposited(user), 1000e6);

        vm.stopPrank();
    }

    function test_Deposit_TransfersTokens() public {
        vm.startPrank(user);

        uint256 userBalanceBefore = usdc.balanceOf(user);
        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        assertEq(usdc.balanceOf(user), userBalanceBefore - 1000e6);
        assertEq(usdc.balanceOf(address(vault)), vaultBalanceBefore + 1000e6);

        vm.stopPrank();
    }

    function test_Deposit_RevertsOnZeroAmount() public {
        vm.startPrank(user);

        vm.expectRevert(UMIPVault.InvalidAmount.selector);
        vault.deposit(0);

        vm.stopPrank();
    }

    function test_Deposit_EmitsEvent() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);

        vm.expectEmit(true, false, false, true);
        emit UMIPVault.Deposited(user, 1000e6, 1000e6);

        vault.deposit(1000e6);

        vm.stopPrank();
    }

    // ============================================
    // Day 2: Withdraw Tests
    // ============================================

    function test_Withdraw_IdleCollateral() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        vault.withdraw(400e6);

        assertEq(vault.userIdleCollateral(user), 600e6, "Idle should be 600");
        assertEq(vault.userTotalDeposited(user), 600e6, "Total should be 600");
        assertEq(usdc.balanceOf(user), INITIAL_BALANCE - 600e6, "User should have withdrawn 400");

        vm.stopPrank();
    }

    function test_Withdraw_EntireBalance() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        vault.withdraw(1000e6);

        assertEq(vault.userIdleCollateral(user), 0, "Idle should be 0");
        assertEq(vault.userTotalDeposited(user), 0, "Total should be 0");
        assertEq(usdc.balanceOf(user), INITIAL_BALANCE, "User should have full balance back");

        vm.stopPrank();
    }

    function test_Withdraw_RevertsOnInsufficientIdle() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                UMIPVault.InsufficientIdleCollateral.selector,
                1500e6,
                1000e6
            )
        );
        vault.withdraw(1500e6);

        vm.stopPrank();
    }

    function test_Withdraw_RevertsOnZeroAmount() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        vm.expectRevert(UMIPVault.InvalidAmount.selector);
        vault.withdraw(0);

        vm.stopPrank();
    }

    function test_Withdraw_EmitsEvent() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        vm.expectEmit(true, false, false, true);
        emit UMIPVault.Withdrawn(user, 400e6, 600e6);

        vault.withdraw(400e6);

        vm.stopPrank();
    }

    // ============================================
    // Day 2: Invariant Tests
    // ============================================

    function test_Invariant_AfterDeposit() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 5000e6);
        vault.deposit(1000e6);
        assertTrue(vault.checkInvariant(user), "Invariant should hold after deposit");

        vault.deposit(2000e6);
        assertTrue(vault.checkInvariant(user), "Invariant should hold after second deposit");

        vm.stopPrank();
    }

    function test_Invariant_AfterWithdraw() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 2000e6);
        vault.deposit(2000e6);

        vault.withdraw(500e6);
        assertTrue(vault.checkInvariant(user), "Invariant should hold after withdraw");

        vault.withdraw(500e6);
        assertTrue(vault.checkInvariant(user), "Invariant should hold after second withdraw");

        vm.stopPrank();
    }

    // ============================================
    // Day 3: Position Opening Tests
    // ============================================

    function test_OpenPosition_GMX() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        uint256 positionId = vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.GMX,
            400e6,      // collateral
            2000e30,    // size
            type(uint256).max
        );

        // Check collateral accounting
        assertEq(vault.userIdleCollateral(user), 600e6, "Idle should be 600");
        assertEq(vault.userAllocatedToGMX(user), 400e6, "Allocated GMX should be 400");
        assertEq(vault.userAllocatedToVertex(user), 0, "Allocated Vertex should be 0");
        assertTrue(vault.checkInvariant(user), "Invariant should hold");

        // Check position tracking
        assertEq(positionId, 0, "First position should be ID 0");
        assertEq(vault.userPositionCount(user), 1, "Should have 1 position");

        vm.stopPrank();
    }

    function test_OpenPosition_Vertex() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        uint256 positionId = vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.Vertex,
            300e6,
            1500e30,
            type(uint256).max
        );

        assertEq(vault.userIdleCollateral(user), 700e6, "Idle should be 700");
        assertEq(vault.userAllocatedToGMX(user), 0, "Allocated GMX should be 0");
        assertEq(vault.userAllocatedToVertex(user), 300e6, "Allocated Vertex should be 300");
        assertTrue(vault.checkInvariant(user), "Invariant should hold");

        vm.stopPrank();
    }

    function test_OpenPosition_MultiPlatform() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        // Open GMX position
        vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.GMX,
            400e6,
            2000e30,
            type(uint256).max
        );

        // Open Vertex position
        vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.Vertex,
            300e6,
            1500e30,
            type(uint256).max
        );

        // Check accounting
        assertEq(vault.userIdleCollateral(user), 300e6, "Idle should be 300");
        assertEq(vault.userAllocatedToGMX(user), 400e6, "Allocated GMX should be 400");
        assertEq(vault.userAllocatedToVertex(user), 300e6, "Allocated Vertex should be 300");

        // Verify invariant: 300 + 400 + 300 = 1000
        assertTrue(vault.checkInvariant(user), "Invariant should hold");

        (uint256 idle, uint256 gmx, uint256 vertex,, uint256 total) = vault.getUserCollateral(user);
        assertEq(idle + gmx + vertex, total, "Sum should equal total");
        assertEq(total, 1000e6, "Total should be 1000");

        vm.stopPrank();
    }

    function test_OpenPosition_RevertsOnInsufficientCollateral() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 500e6);
        vault.deposit(500e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                UMIPVault.InsufficientIdleCollateral.selector,
                600e6,
                500e6
            )
        );
        vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.GMX,
            600e6,
            3000e30,
            type(uint256).max
        );

        vm.stopPrank();
    }

    function test_CannotWithdrawAllocatedCollateral() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        // Open position with 600 USDC
        vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.GMX,
            600e6,
            3000e30,
            type(uint256).max
        );

        // Only 400 idle - try to withdraw 500
        vm.expectRevert(
            abi.encodeWithSelector(
                UMIPVault.InsufficientIdleCollateral.selector,
                500e6,
                400e6
            )
        );
        vault.withdraw(500e6);

        // Can withdraw up to 400
        vault.withdraw(400e6);
        assertEq(vault.userIdleCollateral(user), 0);
        assertEq(vault.userAllocatedToGMX(user), 600e6);

        vm.stopPrank();
    }

    // ============================================
    // Day 4: Position Closing Tests
    // ============================================

    function test_ClosePosition_ReturnsCollateralToIdle() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        // Open position
        uint256 positionId = vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.GMX,
            400e6,
            2000e30,
            type(uint256).max
        );

        assertEq(vault.userIdleCollateral(user), 600e6, "Idle before close");
        assertEq(vault.userAllocatedToGMX(user), 400e6, "Allocated before close");

        // Close position
        vault.closePosition{value: 0.001 ether}(positionId);

        assertEq(vault.userIdleCollateral(user), 1000e6, "Idle after close");
        assertEq(vault.userAllocatedToGMX(user), 0, "Allocated after close");
        assertTrue(vault.checkInvariant(user), "Invariant should hold");

        vm.stopPrank();
    }

    function test_ClosePosition_VertexReturnsToIdle() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        uint256 positionId = vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.Vertex,
            500e6,
            2500e30,
            type(uint256).max
        );

        vault.closePosition{value: 0.001 ether}(positionId);

        assertEq(vault.userIdleCollateral(user), 1000e6);
        assertEq(vault.userAllocatedToVertex(user), 0);
        assertTrue(vault.checkInvariant(user));

        vm.stopPrank();
    }

    function test_HubAndSpokeFlow() public {
        vm.startPrank(user);

        // Deposit 1000
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);
        assertEq(vault.userIdleCollateral(user), 1000e6, "Start: 1000 idle");

        // Open GMX position (400)
        uint256 gmxPos = vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.GMX,
            400e6,
            2000e30,
            type(uint256).max
        );
        assertEq(vault.userIdleCollateral(user), 600e6, "After GMX open: 600 idle");
        assertEq(vault.userAllocatedToGMX(user), 400e6, "After GMX open: 400 allocated");

        // Open Vertex position (300)
        uint256 vertexPos = vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.Vertex,
            300e6,
            1500e30,
            type(uint256).max
        );
        assertEq(vault.userIdleCollateral(user), 300e6, "After Vertex open: 300 idle");
        assertEq(vault.userAllocatedToVertex(user), 300e6, "After Vertex open: 300 allocated");

        // Close GMX position
        vault.closePosition{value: 0.001 ether}(gmxPos);
        assertEq(vault.userIdleCollateral(user), 700e6, "After GMX close: 700 idle");
        assertEq(vault.userAllocatedToGMX(user), 0, "After GMX close: 0 GMX allocated");
        assertEq(vault.userAllocatedToVertex(user), 300e6, "Vertex still allocated");

        // Now can allocate that 700 to either platform
        vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.Vertex,
            400e6,
            2000e30,
            type(uint256).max
        );
        assertEq(vault.userIdleCollateral(user), 300e6);
        assertEq(vault.userAllocatedToVertex(user), 700e6, "Vertex now has 700");

        assertTrue(vault.checkInvariant(user), "Final invariant check");

        vm.stopPrank();
    }

    function test_ClosePosition_RevertsOnInvalidId() public {
        vm.startPrank(user);

        vm.expectRevert(
            abi.encodeWithSelector(UMIPVault.PositionNotFound.selector, 999)
        );
        vault.closePosition(999);

        vm.stopPrank();
    }

    function test_ClosePosition_RevertsOnAlreadyClosed() public {
        vm.startPrank(user);

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        uint256 positionId = vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.GMX,
            400e6,
            2000e30,
            type(uint256).max
        );

        vault.closePosition{value: 0.001 ether}(positionId);

        vm.expectRevert(
            abi.encodeWithSelector(UMIPVault.PositionAlreadyClosed.selector, positionId)
        );
        vault.closePosition{value: 0.001 ether}(positionId);

        vm.stopPrank();
    }

    // ============================================
    // Critical Invariant Test
    // ============================================

    function testInvariant_CollateralConservation() public {
        vm.startPrank(user);

        // User deposits 1000 USDC
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6);

        // Opens 400 USDC position on GMX
        vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.GMX,
            400e6,
            2000e30,
            type(uint256).max
        );

        // Opens 300 USDC position on Vertex
        vault.openPosition{value: 0.001 ether}(
            UMIPVault.Platform.Vertex,
            300e6,
            1500e30,
            type(uint256).max
        );

        // Check: idle = 300, allocatedGMX = 400, allocatedVertex = 300
        (uint256 idle, uint256 gmx, uint256 vertex,, uint256 total) = vault.getUserCollateral(user);

        assertEq(idle, 300e6, "Idle should be 300");
        assertEq(gmx, 400e6, "GMX should be 400");
        assertEq(vertex, 300e6, "Vertex should be 300");
        assertEq(total, 1000e6, "Total should be 1000");

        // Check: total = 1000
        assertEq(idle + gmx + vertex, total, "Sum equals total");

        // Invariant holds
        assertTrue(vault.checkInvariant(user), "Conservation invariant");

        vm.stopPrank();
    }
}

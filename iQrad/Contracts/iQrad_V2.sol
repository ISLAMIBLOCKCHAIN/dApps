// SPDX-License-Identifier: MIT

// iQrad V2
// Advanced Loan System
// Zero Interest Fees
// Shariah Compliant

pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface iGoldContract {
    function sell(uint256 _iGoldAmount) external returns(uint256);
    function calculateUSDTReceivedForIGold(uint256 _iGoldAmount) external returns (uint256);
    function calculateIGoldReceivedForUSDT(uint256 _usdtAmount) external  returns (uint256);
    function addUSDT(uint256 _amount) external;
}

interface IBuyAndBurn{
    function buyAndBurn(address, uint256) external returns(uint256);
}

interface IPMMContract {
    enum RState {
        ONE,
        ABOVE_ONE,
        BELOW_ONE
    }

    function querySellQuote(address trader, uint256 payQuoteAmount)
        external
        view
        returns (
            uint256 receiveBaseAmount,
            uint256 mtFee,
            RState newRState,
            uint256 newQuoteTarget
        );
}

contract iQrad_V2 is Ownable {

    IPMMContract public pmmContract = IPMMContract(0x14afbB9E6Ab4Ab761f067fA131e46760125301Fc);
    AggregatorV3Interface public goldPriceFeed = AggregatorV3Interface(0x0C466540B2ee1a31b441671eac0ca886e051E410);

    uint256 public constant oneMonth = 30 days;

    IBuyAndBurn public BAB = IBuyAndBurn(0xd73501d9111FF2DE47acBD52D2eAeaaA9e02b4Dd);
    iGoldContract public iGoldc =
        iGoldContract(0xf2B1114C644cBb3fF63Bf1dD284c8Cd716e95BE9);// 0xaa3281f63157BbeC4Bf34F54480A6226dF80B133);

    address public deadWallet = 0x000000000000000000000000000000000000dEaD;

    address public islamiToken = 0x2E9d30761DB97706C536A112B9466433032b28e3;// 0x942714c1da04Cc66362aad2132A36e896491d353;
    address public iGoldToken = 0xf2B1114C644cBb3fF63Bf1dD284c8Cd716e95BE9;// 0xaa3281f63157BbeC4Bf34F54480A6226dF80B133;
    address public usdtToken = 0xDA07165D4f7c84EEEfa7a4Ff439e039B7925d3dF;// 0xC7185282aafDD110E549f2A06167CB81f3F3E1d0;

    address private defaultHandler = 0x1be6cF82aC405cC46D35895262Fa83f582D42884;

    uint256 private fileFee = 1500000; // 1.5 USDT
    uint256 private investorFile = 3000000; // 3 USDT
    
    // uint256 public minLoanAmountTwoYears = 500 * (1e6);
    // uint256 public minLoanAmountOneYear = 500 * (1e6);
    uint256 public minLoanAmountDefault = 30 * (1e6);

    uint256 private loanFee = 500000; // 0.5 USDT
    
    uint256 public loanPercentage = 65;

    uint256 private toBurn = 40; // 40%
    uint256 private toFee = 60; // 60%

    // uint256 public iGoldPrice = uint256(getIGoldPrice());

    /* Testing Variables */
    bool public isTesting = true;
    uint256 public testingMinLoanAmount = 5 * (1e6); // 5 USDT for testing
    /* Testing Variables */

    uint256 public usdtVault;
    uint256 public usdtInLoans;
    uint256 public iGoldVault;
    uint256 public iGoldSold;
    uint256 public burnedISLAMI;
    
    uint256 public activeLoans;

    address[] public investors;
    address[] public activeLoanUsers;

    uint256 private mUSDT = 1; // multiply by value
    uint256 private dUSDT = 100; // divide by value

    enum LoanStatus {
        NONE,
        ACTIVE,
        DEFAULTED,
        CLOSED
    }
    enum LoanTenure {
        NONE,
        ONE_MONTH,
        THREE_MONTHS,
        SIX_MONTHS,
        ONE_YEAR,
        TWO_YEARS
    }

    struct AngelInvestor {
        uint256 vault;
        uint256 depositAmount;
        uint256 availableAmount;
        uint256 depositTime;
        uint256 duration;
    }

    struct InvestorVaults {
        address investor;
        AngelInvestor[] vaults;
    }

    struct SelectedVault {
        address investorAddress;
        uint256 vaultId;
        uint256 amountAllocated;
    }

    struct User {
        bool hasFile;
        uint256 collateral;
        uint256 loanAmount;
        uint256 monthlyPayment;
        uint256 lastPaymentTime;
        uint256 nextPaymentTime;
        LoanStatus status;
        LoanTenure tenure;
        uint256 loanStartDate;
        uint256 paymentsLeft;
    }

    mapping(address => mapping(uint256 => AngelInvestor)) public angelInvestors;
    mapping(address => uint256) public nextVaultId;
    mapping(address => uint256) public vaultsCount;
    mapping(address => User) public users;
    mapping(address => SelectedVault[]) public selectedVaults;
    mapping(address => bool) public isInvestor;
    mapping(address => bool) public hasLoan;
    mapping(address => bool) public hasInvestorFile;

    event AngelInvestorDeposited(
        address indexed investor,
        uint256 vaultID,
        uint256 amount
    );
    event AngelInvestorWithdrawn(
        address indexed investor,
        uint256 vaultID,
        uint256 amount
    );
    event FileOpened(address indexed user);
    event CollateralDeposited(address indexed user, uint256 amount);
    event LoanTaken(address indexed user, uint256 amount);
    event MonthlyPaymentMade(address indexed user, uint256 amount, uint256 payemtsDue);
    event LoanDefaulted(address indexed user, uint256 iGoldSold, uint256 paymentAmount, uint256 feePaid, uint256 paymentsDue);
    event LoanClosed(address indexed user);
    event LoanRepaid(address indexed user);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event AngelInvestorDurationExtended(address indexed investor, uint256 vaultID, uint256 newDuration);
    event TestingPeriodEnded();

    modifier hasFile(address _user) {
        require(users[_user].hasFile, "File not opened");
        _;
    }

    modifier hasActiveLoan(address _user) {
        require(users[_user].status == LoanStatus.ACTIVE, "No active loan");
        _;
    }

    constructor() {
    }

    /* Testing Function */
    function endTesting() external onlyOwner {
        require(isTesting, "Testing period already ended");
        isTesting = false;
        emit TestingPeriodEnded();
    }
    /* Testing Function */

    function editUSDTFee(uint256 _m, uint256 _d) external onlyOwner{
        require(_m >= 1 && _d > 99, "Multiply equal or over 1 and divide over 99");
        mUSDT = _m;
        dUSDT = _d;
    }

    function approveAll()external{
        IERC20(islamiToken).approve(iGoldToken, type(uint256).max);
        IERC20(usdtToken).approve(iGoldToken, type(uint256).max);
        IERC20(usdtToken).approve(address(BAB), type(uint256).max);
    }

    function setBabContractAddress(address _BAB) external onlyOwner {
        require(_BAB != address(0), "Zero Address");
        BAB = IBuyAndBurn(_BAB);
    }

    function setBurnFee(uint256 _toBurn, uint256 _toFee) external onlyOwner{
        require(_toBurn + _toFee == 100, "Percentage error");
        toBurn = _toBurn;
        toFee = _toFee;
    }

    function oneTimeFee() public view returns(uint256){
        return getIslamiPrice(fileFee);
    }

    function serviceFee() public view returns(uint256){
        return getIslamiPrice(loanFee);
    }

    function investorFee() public view returns(uint256){
        if(isTesting){
            return investorFile / 60;
        }else{
            return investorFile;
        }
    }

    function setISLAMIaddress(address _new) external onlyOwner{
        require(_new != address(0),"Zero address");
        islamiToken = _new;
    }

    function setiGoldAddress(address _new) external onlyOwner{
        require(_new != address(0),"Zero address");
        iGoldToken = _new;
    }

/* Start of Investor Functions */


    function depositAsAngelInvestor(uint256 amount, uint256 _duration)
        external
    {
        if(isTesting){
            require(amount > testingMinLoanAmount, "Deposit amount must be greater than 0");
        } else{
            require(amount > minLoanAmountDefault, "Deposit amount must be greater than minLoanAmount");
        }
        require(_duration >= 9, "Deposite should be at least for 9 Months");

        if(!hasInvestorFile[msg.sender]){
            require(IERC20(usdtToken).transferFrom(msg.sender, address(this), investorFee()), "USDT fee failed");
            uint256 fee1 = investorFee() / 3;
            uint256 fee2 = investorFee() - fee1 ;
            iGoldc.addUSDT(fee1);
            require(IERC20(usdtToken).transfer(defaultHandler, fee2), "Handler fee");
            hasInvestorFile[msg.sender] = true;
        }

        if(nextVaultId[msg.sender] == 0){
            nextVaultId[msg.sender] = 1;
        }
        uint256 vaultId = nextVaultId[msg.sender];
        

        require(
            IERC20(usdtToken).transferFrom(msg.sender, address(this), amount),
            "Deposit failed"
        );

        AngelInvestor storage investor = angelInvestors[msg.sender][vaultId];
        investor.depositAmount += amount;
        investor.availableAmount += amount;
        investor.vault = vaultId; // Set the vault ID
        investor.depositTime = block.timestamp; // Set the deposit time
        investor.duration = isTesting? (_duration * 300) + block.timestamp : (_duration * oneMonth) + block.timestamp;

        usdtVault += amount;
        nextVaultId[msg.sender]++; // Increment the vault ID for the next deposit
        vaultsCount[msg.sender]++;

        if (!isInvestor[msg.sender]) {
            isInvestor[msg.sender] = true;
            investors.push(msg.sender);
        }

        emit AngelInvestorDeposited(msg.sender, vaultId, amount);
    }

    function getInvestorVaults(address investor)
        external
        view
        returns (AngelInvestor[] memory)
    {
        uint256 vaultCount = nextVaultId[investor];

        // First pass to count non-empty vaults
        uint256 nonEmptyCount = 0;
        for (uint256 i = 1; i < vaultCount; i++) {
            if (angelInvestors[investor][i].depositAmount > 0) {
                nonEmptyCount++;
            }
        }

        // Initialize the array with the size of non-empty vaults
        AngelInvestor[] memory investorVaults = new AngelInvestor[](nonEmptyCount);

        // Second pass to fill the array
        uint256 arrayIndex = 0;
        for (uint256 i = 1; i < vaultCount; i++) {
            if (angelInvestors[investor][i].depositAmount > 0) {
                investorVaults[arrayIndex] = angelInvestors[investor][i];
                arrayIndex++;
            }
        }

        return investorVaults;
    }

    function isExtendable(address investor, uint256 vaultId) public view returns (bool) {
        AngelInvestor memory investorVault = angelInvestors[investor][vaultId];
        // Calculate the remaining duration in seconds
        uint256 remainingDuration = investorVault.duration > block.timestamp ? investorVault.duration - block.timestamp : 0;
        // Convert 6 months to seconds for comparison
        uint256 sixMonths = isTesting ? 6 * 300 : 6 * oneMonth; // Adjust based on whether we're in testing mode
        // Check if the remaining duration is less than 6 months
        return remainingDuration < sixMonths;
    }


    function extendAngelDeposit(uint256 vaultId, uint256 additionalDuration) external {
        require(vaultId < nextVaultId[msg.sender], "Invalid vault ID");
        AngelInvestor storage investor = angelInvestors[msg.sender][vaultId];

        // Calculate the minimum additional duration to extend the deposit to at least 6 months from now
        uint256 remainingDuration = investor.duration > block.timestamp ? investor.duration - block.timestamp : 0;
        uint256 sixMonths = isTesting ? 6 * 300 : 6 * oneMonth; // Adjust based on whether we're in testing mode
        require(remainingDuration < sixMonths, "Deposit extension not allowed. More than 6 months remaining.");

        // Ensure the new duration is at least 6 months from now if the remaining duration is less
        if (remainingDuration + (additionalDuration * oneMonth) < sixMonths) {
            additionalDuration = (sixMonths - remainingDuration) / oneMonth + 1; // Adjust the additionalDuration to meet the 6 months requirement
        }

        // Extend the duration
        if(isTesting){
            investor.duration += additionalDuration * 300; // Adjust for testing
        } else{
            investor.duration += additionalDuration * oneMonth; // Adjust for production
        }
        
        emit AngelInvestorDurationExtended(msg.sender, vaultId, investor.duration);
    }



    function withdrawFromAngelInvestor(uint256 vaultId)
        external
    {
        require(vaultId < nextVaultId[msg.sender], "Invalid vault ID");
        AngelInvestor storage investor = angelInvestors[msg.sender][vaultId];
        // require(block.timestamp >= investor.duration, "Withdraw is not yet");

        uint256 amount = investor.availableAmount;

        require(
            IERC20(usdtToken).transfer(msg.sender, amount),
            "Withdrawal failed"
        );

        usdtVault -= amount;
        investor.depositAmount -= amount;
        investor.availableAmount -= amount;

        if (investor.depositAmount == 0) {
            investor.depositTime = 0;
            investor.vault = 0;
            vaultsCount[msg.sender]--;
            if(vaultsCount[msg.sender] == 0){
                removeInvestorIfNoVaults(msg.sender);
            }
        }

        emit AngelInvestorWithdrawn(msg.sender, vaultId, amount);
    }


/* End of Investor Functions */
/****************************/

/* Start of User Functions */

    function requestLoan(uint256 collateralAmount, LoanTenure tenure) external {
        // Step 1: Open File
        if(!users[msg.sender].hasFile){
            _openFile(msg.sender);
        }

        // Step 2: Deposit Collateral
        _depositCollateral(msg.sender, collateralAmount);

        // Step 3: Take Loan
        _takeLoan(msg.sender, collateralAmount, tenure);
    }

    function _openFile(address user) internal {
        uint256 _oneTimeFee = oneTimeFee();
        require(
            IERC20(islamiToken).transferFrom(user, deadWallet, _oneTimeFee),
            "Fee transfer failed"
        );
        users[user].hasFile = true;
        burnedISLAMI += _oneTimeFee;
        emit FileOpened(user);
    }

    function _depositCollateral(address user, uint256 amount)
        internal
        hasFile(user)
    {
        require(
            IERC20(iGoldToken).transferFrom(user, address(this), amount),
            "Transfer failed"
        );
        iGoldVault += amount;
        users[user].collateral += amount;
        emit CollateralDeposited(user, amount);
    }

    function _takeLoan(
        address user,
        uint256 collateralAmount,
        LoanTenure tenure
    ) internal hasFile(user) {

        require(!hasLoan[user],"iQrad: User has loan already");

        users[user].loanStartDate = block.timestamp;

        // Calculate the total value of the iGold collateral
        // uint256 collateralValue = iGoldc.calculateUSDTReceivedForIGold(collateralAmount);

        // Calculate the maximum loan amount as 65% of the collateral value
        uint256 amount = getUSDTAmountForLoan(collateralAmount);

        uint256 minLoanAmount = isTesting ? testingMinLoanAmount : minLoanAmountDefault;
        uint256 maxAmount = getDynamicMaxLoanAmount(tenure);

        require(amount >= minLoanAmount, "iQrad: Loan amount is less than minimum required for the duration");
        require(amount <= maxAmount, "iQrad: Loan amount is more than maximum allowed");

        // Transfer service fee to deadWallet
        IERC20(islamiToken).transferFrom(msg.sender, deadWallet, serviceFee());
        burnedISLAMI += serviceFee();

        require(
            IERC20(usdtToken).balanceOf(address(this)) >= amount,
            "Insufficient USDT in vaults"
        );

        // Select a vault from which to take the loan
        _selectVaultsForLoan(user, amount, tenure);
    

        uint8 _tenure;
        if (tenure == LoanTenure.ONE_MONTH) {
            _tenure = 1 ;
        } else if (tenure == LoanTenure.THREE_MONTHS) {
            _tenure = 3 ;
        } else if (tenure == LoanTenure.SIX_MONTHS) {
            _tenure = 6 ;
        } else if (tenure == LoanTenure.ONE_YEAR) {
            _tenure = 12 ;
        } else if (tenure == LoanTenure.TWO_YEARS) {
            _tenure = 24 ;
        }

        uint256 monthlyPayment = amount / _tenure;

        

        usdtInLoans += amount;
        usdtVault -= amount;

        users[user].loanAmount = amount;
        users[user].monthlyPayment = monthlyPayment;
        users[user].lastPaymentTime = block.timestamp;
        users[user].nextPaymentTime = isTesting? block.timestamp + 300 : block.timestamp + oneMonth;
        users[user].status = LoanStatus.ACTIVE;
        users[user].tenure = tenure;
        users[user].paymentsLeft = _tenure;

        hasLoan[user] = true;
        activeLoanUsers.push(user);
        activeLoans++;

        emit LoanTaken(user, amount);
        require(IERC20(usdtToken).transfer(user, amount), "iQrad: USDT transfer error");
    }

    function _selectVaultsForLoan(address _user, uint256 loanAmount, LoanTenure tenure) internal {
        uint256 tenureDuration = _getTenureDuration(tenure);
        require(tenureDuration > 0, "Invalid loan tenure");

        uint256 totalAvailable = 0;
        SelectedVault[] memory eligibleVaults = new SelectedVault[](3);
        uint256 eligibleCount = 0;

        uint256 earliestEndTime = block.timestamp + tenureDuration;

        // Finding eligible vaults and total available amount
        for (uint256 i = 0; i < investors.length && eligibleCount < 3; i++) {
            address investorAddress = investors[i];
            for (uint256 vaultId = 1; vaultId < nextVaultId[investorAddress]; vaultId++) {
                AngelInvestor storage vault = angelInvestors[investorAddress][vaultId];
                if (vault.availableAmount > 0 && vault.duration >= earliestEndTime) {
                    totalAvailable += vault.availableAmount;
                    eligibleVaults[eligibleCount++] = SelectedVault(investorAddress, vaultId, 0); // Amount allocated later
                }
            }
        }

        require(totalAvailable >= loanAmount, "Insufficient funds across eligible vaults");
        require(eligibleCount > 0, "No eligible vaults found");

        // Allocate loan amount across eligible vaults
        delete selectedVaults[_user];
        uint256 distributedAmount = 0;

        for (uint256 i = 0; i < eligibleCount; i++) {
            // Get the actual available amount from the AngelInvestor struct
            uint256 availableAmount = angelInvestors[eligibleVaults[i].investorAddress][eligibleVaults[i].vaultId].availableAmount;

            uint256 allocation = (loanAmount * availableAmount) / totalAvailable; // Proportional allocation
            if (i == eligibleCount - 1) { // Ensure full loan amount is allocated by adding any remainder to the last vault
                allocation = loanAmount - distributedAmount;
            }

            // Adjust vault availability and record allocation
            angelInvestors[eligibleVaults[i].investorAddress][eligibleVaults[i].vaultId].availableAmount -= allocation;
            eligibleVaults[i].amountAllocated = allocation;
            selectedVaults[_user].push(eligibleVaults[i]);

            distributedAmount += allocation;
        }
    }

    function getUSDTAmountForLoan(uint256 _collateralAmount) public view returns (uint256 loanAmount){
    
        // Calculate the total value of the iGold collateral
        uint256 collateralValue = (_collateralAmount * uint256(getIGoldPrice())) / (1e8);

        // Calculate the maximum loan amount as 65% of the collateral value
        uint256 amount = ((collateralValue * loanPercentage) / 100) / (1e2);
        uint256 onePercentFees = amount / 100;
        uint256 actualReturnAmount = amount - onePercentFees;

        return(actualReturnAmount);
    }

    function _getTenureDuration(LoanTenure tenure) internal view returns (uint256) {
        return _calculateNormalDuration(tenure);
    }

    function _calculateNormalDuration(LoanTenure tenure) private view returns (uint256) {
        if (tenure == LoanTenure.ONE_MONTH) {
            return isTesting ? 5 * 60 : oneMonth; // For testing, you might adjust the duration
        } else if (tenure == LoanTenure.THREE_MONTHS) {
            return isTesting ? 15 * 60 : 90 days;
        } else if (tenure == LoanTenure.SIX_MONTHS) {
            return 180 days;
        } else if (tenure == LoanTenure.ONE_YEAR) {
            return 365 days;
        } else if (tenure == LoanTenure.TWO_YEARS) {
            return 730 days;
        } else {
            revert("Invalid loan tenure");
        }
    }

    function makeMonthlyPayment() external hasActiveLoan(msg.sender) {
        User storage user = users[msg.sender];
        (uint256 overduePayments, uint256 totalDue) = calculateOverduePayments(msg.sender);
        // Adjustments for scenarios where overduePayments or totalDue might be zero
        overduePayments = overduePayments == 0 ? 1 : overduePayments;
        totalDue = totalDue == 0 ? user.monthlyPayment : totalDue;

        // Ensure the user has sufficient balance for the payment.
        require(IERC20(usdtToken).balanceOf(msg.sender) >= totalDue, "Insufficient balance for payment");
        
        // Check if Last Payment
        uint256 tolerance = 1; // 1 wei tolerance for rounding errors
        if (user.loanAmount <= totalDue + tolerance) {
            _repayLoan(msg.sender);
        } else {
            // Proceed with the normal payment process for overdue payments.
            require(IERC20(usdtToken).transferFrom(msg.sender, address(this), totalDue), "Payment failed");
            // Update the state to reflect the payment
            usdtInLoans -= totalDue;
            usdtVault += totalDue;
            user.lastPaymentTime = block.timestamp;
            user.loanAmount -= totalDue;
            user.paymentsLeft -= overduePayments;

            updateNextPaymentTime(msg.sender);

            emit MonthlyPaymentMade(msg.sender, users[msg.sender].monthlyPayment, overduePayments);

            for(uint256 i = 0; i < overduePayments; i++) {
                _updateVaults(msg.sender); // Update vaults for each overdue payment.
            }
        }
    }

    function _toDefault(address _user) internal view returns(uint256, uint256, uint256){
         // Get the current price of iGold in terms of USDT
        uint256 _iGoldPrice = uint256(getIGoldPrice() / (1e2));
        require(_iGoldPrice > 0, "Invalid iGold price");

        (uint256 overduePayments, uint256 totalDue) = calculateOverduePayments(_user);
        uint256 defaultFee = totalDue / 100; // 1% of the user monthly payment
        uint256 defaultPayment = totalDue + defaultFee;
        uint256 iGoldFee = (defaultPayment * mUSDT / dUSDT) * 2;
        uint256 finalAmount = defaultPayment + iGoldFee;
        return (overduePayments, totalDue, finalAmount);
    }

    function handleDefault(address _user) public hasActiveLoan(_user) {
        User storage user = users[_user];
        require(block.timestamp >= user.nextPaymentTime, "Not a default case");

        (uint256 overduePayments, uint256 totalDue, uint256 finalAmount) = _toDefault(_user);
        uint256 totaliGoldToSell = iGoldc.calculateIGoldReceivedForUSDT(finalAmount);

        if(user.collateral < totaliGoldToSell){
            totaliGoldToSell = user.collateral;
        }

        uint256 usdtReceived = iGoldc.sell(totaliGoldToSell);
        uint256 actualUsdtReceived = usdtReceived - (usdtReceived * mUSDT / dUSDT);

        require(actualUsdtReceived >= totalDue, "USDT received is less than the monthly fee");

        iGoldVault -= totaliGoldToSell;
        usdtVault += actualUsdtReceived - (actualUsdtReceived - totalDue);
        user.collateral -= totaliGoldToSell;

        uint256 tolerance = 1; // 1 wei tolerance for rounding errors
        if (user.loanAmount <= totalDue + tolerance) {
            user.loanAmount = 0; // Consider the loan fully repaid if within tolerance
            repayInvestors(_user);
        } else {
            user.loanAmount -= totalDue;
            for(uint256 i = 0; i < overduePayments; i++) {
                _updateVaults(_user); // Adjust the vaults for each overdue payment.
            }
            user.paymentsLeft -= overduePayments;
        }

        user.lastPaymentTime = block.timestamp;
        updateNextPaymentTime(_user);

        emit LoanDefaulted(_user, totaliGoldToSell, totalDue, actualUsdtReceived - totalDue, overduePayments);
    }

    function updateNextPaymentTime(address _user) private {
        User storage user = users[_user];
        // Calculate the next payment time based on the current date and payment frequency
        uint256 monthsSinceStart = (block.timestamp - user.loanStartDate) / oneMonth;
        user.nextPaymentTime = isTesting ? block.timestamp + 300 : user.loanStartDate + ((monthsSinceStart + 1) * oneMonth);
    }

    function repayInvestors(address _user) private {
        SelectedVault[] storage vaults = selectedVaults[_user];
        for(uint256 i = 0; i < vaults.length; i++){
            uint256 allocation = vaults[i].amountAllocated;
            angelInvestors[vaults[i].investorAddress][vaults[i].vaultId].availableAmount += allocation;
        }
        closeLoan(_user);
    }


    function _updateVaults(address _user) private{
        User storage user = users[_user];
        SelectedVault[] storage vaults = selectedVaults[_user];
        uint256 payemt = user.monthlyPayment;
        // The payment is divided equally among all the selected vaults
        uint256 vaultCount = vaults.length;
        uint256 paymentPerVault = payemt / vaultCount;
        uint256 remainder = payemt % vaultCount; // Remainder that needs to be distributed

        uint256 totalDistributedPayment = 0; // Track the total payment distributed

        for (uint256 i = 0; i < vaultCount; i++) {
            uint256 paymentForThisVault = paymentPerVault;

            // Distribute the remainder among the first few vaults until it's exhausted
            if (remainder > 0) {
                paymentForThisVault += 1;
                remainder -= 1;
            }

            // Update the allocated amount for the loan in each vault
            if (vaults[i].amountAllocated >= paymentForThisVault) {
                vaults[i].amountAllocated -= paymentForThisVault;
                totalDistributedPayment += paymentForThisVault;
            } else {
                // In case the allocated amount is less than the calculated payment, just adjust with what's left
                totalDistributedPayment += vaults[i].amountAllocated;
                vaults[i].amountAllocated = 0;
            }

            // Update the available amount for the angel investor's vault
            AngelInvestor storage investorVault = angelInvestors[vaults[i].investorAddress][vaults[i].vaultId];
            // Add the payment back to the available amount of the investor's vault
            uint256 potentialNewAvailableAmount = investorVault.availableAmount + paymentForThisVault;
            
            // Ensure the new available amount does not exceed the initial deposit amount
            if (potentialNewAvailableAmount > investorVault.depositAmount) {
                potentialNewAvailableAmount = investorVault.depositAmount;
            }

            // Update the investor vault's available amount
            investorVault.availableAmount = potentialNewAvailableAmount;
        }
    }

    function closeLoan(address _user) internal hasActiveLoan(_user) {
        User storage user = users[_user];

        // Check if the entire loan amount has been repaid
        require(
            user.loanAmount == 0,
            "Loan amount must be fully repaid to close the loan"
        );

        // Calculate the remaining collateral to be returned
        uint256 remainingCollateral = user.collateral;

        // Transfer the remaining collateral back to the user
        require(
            IERC20(iGoldToken).transfer(_user, remainingCollateral),
            "Collateral transfer failed"
        );

        iGoldVault -= remainingCollateral;

        // Update the user's loan status to CLOSED
        user.status = LoanStatus.CLOSED;

        // Reset other loan-related variables
        user.collateral = 0;
        user.loanAmount = 0;
        user.monthlyPayment = 0;
        user.lastPaymentTime = 0;
        user.nextPaymentTime = 0;
        user.tenure = LoanTenure.NONE;
        user.loanStartDate = 0;

        hasLoan[_user] = false;
        _removeActiveLoanUser(_user);
        activeLoans--;

        emit LoanClosed(_user);
    }

    function repayLoan() public hasActiveLoan(msg.sender){
        _repayLoan(msg.sender);
    }

    function _repayLoan(address _user) private {
        User storage user = users[_user];
        uint256 remainingLoan = user.loanAmount;
        require(
            IERC20(usdtToken).transferFrom(
                _user,
                address(this),
                remainingLoan
            ),
            "Repayment failed"
        );

        // Update investors vaults
        SelectedVault[] storage vaults = selectedVaults[_user];
        for(uint256 i = 0; i < vaults.length; i++){
            uint256 allocation = vaults[i].amountAllocated;
            angelInvestors[vaults[i].investorAddress][vaults[i].vaultId].availableAmount += allocation;
        }
        usdtVault += remainingLoan;

        user.loanAmount = 0;
        user.status = LoanStatus.CLOSED;

        // Transfer back the collateral to the user
        uint256 collateral = user.collateral;
        require(
            IERC20(iGoldToken).transfer(_user, collateral),
            "Collateral transfer failed"
        );

        iGoldVault -= collateral;
        usdtInLoans -= remainingLoan;
        user.collateral = 0;
        user.monthlyPayment = 0;
        user.lastPaymentTime = 0;
        user.nextPaymentTime = 0;
        user.tenure = LoanTenure.NONE;
        user.loanStartDate = 0;
        user.paymentsLeft = 0;

        hasLoan[_user] = false;
        _removeActiveLoanUser(_user);
        activeLoans--;

        emit LoanRepaid(_user);
    }

    // function withdrawCollateral(uint256 amount) external hasFile(msg.sender) {
    //     require(
    //         users[msg.sender].status == LoanStatus.CLOSED,
    //         "Loan not closed"
    //     );
    //     require(
    //         users[msg.sender].collateral >= amount,
    //         "Insufficient collateral"
    //     );

    //     require(
    //         IERC20(iGoldToken).transfer(msg.sender, amount),
    //         "Collateral withdrawal failed"
    //     );
    //     users[msg.sender].collateral -= amount;

    //     emit CollateralWithdrawn(msg.sender, amount);
    // }

    function updateFileFee(uint256 newFee) external onlyOwner {
        fileFee = newFee;
    }

    function updateInvestorFee(uint256 newFee) external onlyOwner {
        investorFile = newFee;
    }

    function iGoldBalance(address _user) public view returns(uint256 _balance){
        _balance = IERC20(iGoldToken).balanceOf(address(_user));
        return _balance;
    }

    function ISLAMIbalance(address _user) public view returns(uint256 _balance){
        _balance = IERC20(islamiToken).balanceOf(address(_user));
        return _balance;
    }

    function usdtBalance(address _user) public view returns(uint256 _balance){
        _balance = IERC20(usdtToken).balanceOf(address(_user));
        return _balance;
    }

    function setLoanFee(uint256 _newLoanFee) external onlyOwner {
        require(_newLoanFee > 0, "Loan fee must be greater than zero");
        loanFee = _newLoanFee;
    }

    function setMinLoanAmounts(uint256 _default) external onlyOwner {
        minLoanAmountDefault = _default * (1e6);
    }

    function getAllInvestorsVaults() external view returns (InvestorVaults[] memory) {
        InvestorVaults[] memory allInvestorVaults = new InvestorVaults[](investors.length);

        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            uint256 vaultCount = vaultsCount[investor]; 

            AngelInvestor[] memory vaults = new AngelInvestor[](vaultCount);
            
            // Start from 1 since your vaults seem to be 1-indexed
            for (uint256 j = 1; j <= vaultCount; j++) {
                AngelInvestor storage investorVault = angelInvestors[investor][j];
                vaults[j - 1] = investorVault; // Adjust index to be 0-indexed for the array
            }

            allInvestorVaults[i] = InvestorVaults({
                investor: investor,
                vaults: vaults
            });
        }

        return allInvestorVaults;
    }


    function getDynamicMaxLoanAmount(LoanTenure tenure) public view returns (uint256) {
        uint256 averageDeposit = usdtVault;
        
        if (tenure == LoanTenure.ONE_MONTH) {
            return averageDeposit * 1 / 100; // 1% of average deposit
        } else if (tenure == LoanTenure.THREE_MONTHS) {
            return averageDeposit * 3 / 100; // 3% of average deposit
        } else if (tenure == LoanTenure.SIX_MONTHS) {
            return averageDeposit * 6 / 100; // 6% of average deposit
        } else if (tenure == LoanTenure.ONE_YEAR) {
            return averageDeposit * 10 / 100; // 10% of average deposit
        } else if (tenure == LoanTenure.TWO_YEARS) {
            return averageDeposit * 20 / 100; // 20% of average deposit
        } else {
            return 0; // For tenure NONE or any undefined tenure
        }
    }

    function removeInvestorIfNoVaults(address investor) internal {
        if (vaultsCount[investor] == 0) { // Assuming 0 or 1 indicates no active vaults
            // Find the investor in the investors array
            for (uint256 i = 0; i < investors.length; i++) {
                if (investors[i] == investor) {
                    // Swap with the last element and remove the last element
                    investors[i] = investors[investors.length - 1];
                    investors.pop();
                    nextVaultId[investor] = 0;
                    isInvestor[investor] = false;
                    break;
                }
            }
        }
    }

    function _removeActiveLoanUser(address user) private {
        for (uint256 i = 0; i < activeLoanUsers.length; i++) {
            if (activeLoanUsers[i] == user) {
                activeLoanUsers[i] = activeLoanUsers[activeLoanUsers.length - 1];
                activeLoanUsers.pop();
                break;
            }
        }
    }

    function checkAndHandleAllDefaults() external{
        // Iterate over the array of users with active loans
        for (uint256 i = 0; i < activeLoanUsers.length; i++) {
            address user = activeLoanUsers[i];
            if (block.timestamp >= users[user].nextPaymentTime && users[user].status == LoanStatus.ACTIVE) {
                handleDefault(user);
            }
        }
    }

    function checkAllDefaults() public view returns(bool areDefaults){
        // Iterate over the array of users with active loans
        for (uint256 i = 0; i < activeLoanUsers.length; i++) {
            address user = activeLoanUsers[i];
            if (block.timestamp >= users[user].nextPaymentTime && users[user].status == LoanStatus.ACTIVE) {
                return true; 
            }
        }
    }

    // Function to check if any payment is due for a given user address
    function isAnyPaymentDue(address userAddress) public view returns (bool) {
        // Check if the user has an active loan
        if (users[userAddress].status != LoanStatus.ACTIVE) {
            return false; // No active loan, so no payment is due
        }

        // Check if the next payment time is past the current block timestamp
        if (block.timestamp >= users[userAddress].nextPaymentTime) {
            return true; // Payment is due
        }

        return false; // No payment is due
    }

    function getIslamiPrice(uint256 payQuoteAmount)
        public
        pure
        returns (uint256 _price)
    {
        // address trader = address(this);
        // // Call the querySellQuote function from the PMMContract
        // (uint256 receiveBaseAmount, , , ) = pmmContract.querySellQuote(
        //     trader,
        //     payQuoteAmount
        // );
        // _price = receiveBaseAmount;
        // return _price;
        _price = 36459672164 * (payQuoteAmount / (1e6));
        return _price;
    }

    function getLatestGoldPriceOunce() public pure returns (int256) {
        // (, int256 pricePerOunce, , , ) = goldPriceFeed.latestRoundData();
        // return pricePerOunce;
        int256 pricePerOunce = 202482000000;
        return pricePerOunce;
    }

    function getLatestGoldPriceGram() public pure returns (int256) {
        int256 pricePerGram = (getLatestGoldPriceOunce() * 1e8) / 3110347680; // Multiplied by 10^8 to handle decimals

        return pricePerGram;
    }

    function getIGoldPrice() public pure returns (int256) {
        int256 _iGoldPrice = (getLatestGoldPriceGram()) / 10;
        return _iGoldPrice;
    }

    function setPMMContract(address _newPMMContract) external onlyOwner {
        require(_newPMMContract != address(0), "Invalid address.");
        pmmContract = IPMMContract(_newPMMContract);
    }

    function setGoldPriceFeed(address _newGoldPriceFeed) external onlyOwner {
        require(_newGoldPriceFeed != address(0), "Invalid address.");
        goldPriceFeed = AggregatorV3Interface(_newGoldPriceFeed);
    }

    function setLoanPercentage(uint256 _percentage) external onlyOwner{
        require(_percentage >= 50 && _percentage <= 70, "Can't set percentage lower than 50 or higher than 70");
        loanPercentage = _percentage;
    }

    // Calculates the number of overdue payments and the total amount due.
    function calculateOverduePayments(address userAddress) public view returns (uint256 overduePayments, uint256 totalDue) {
        User storage user = users[userAddress];
        if (user.status != LoanStatus.ACTIVE) {
            return (0, 0);
        }

        uint256 paymentInterval = isTesting ? 300 : oneMonth; // Adjust for testing mode
        uint256 paymentsSinceStart = (block.timestamp - user.loanStartDate) / paymentInterval;
        uint256 paymentsMade = (user.lastPaymentTime - user.loanStartDate) / paymentInterval;

        overduePayments = paymentsSinceStart - paymentsMade;
        if(overduePayments > user.paymentsLeft){
            overduePayments = user.paymentsLeft;
        }
        totalDue = overduePayments * user.monthlyPayment;
        return (overduePayments, totalDue);
    }


}

                /*********************************************************
                       Developed by Eng. Jaafar Krayem Copyright 2024
                **********************************************************/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface iGoldContract {
    function getIGoldPrice() external returns (int256);
    function getIslamiPrice(uint256 payQuoteAmount) external returns (uint256 _price);
    function sell(uint256 _iGoldAmount) external;
}

contract iQrad_V1 is Ownable {

    uint256 public constant oneMonth = 30 days;

    iGoldContract public iGoldc =
        iGoldContract(0x9440146ea1dF0142eE1892602416DA896c7876E8);

    address public deadWallet = 0x000000000000000000000000000000000000dEaD;

    address public islamiToken = 0x9c891326Fd8b1a713974f73bb604677E1E63396D;
    address public iGoldToken = 0x9440146ea1dF0142eE1892602416DA896c7876E8;
    address public usdtToken = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;

    address public feeReceiver = address(this);//0x1be6cF82aC405cC46D35895262Fa83f582D42884;

    address private defaultHandler = 0x1be6cF82aC405cC46D35895262Fa83f582D42884;

    uint256 public oneTimeFee = 10000 * (1e7); // 10,000 ISLAMI

    uint256 public minLoanAmountTwoYears = 500 * (1e6);
    uint256 public minLoanAmountOneYear = 500 * (1e6);
    uint256 public minLoanAmountDefault = 100 * (1e6);
    uint256 public serviceFee = 3000 * (1e7); // 2 USDT in ISLAMI

    uint256 public iGoldPrice = uint256(iGoldc.getIGoldPrice());

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

    enum LoanStatus {
        NONE,
        ACTIVE,
        DEFAULTED,
        CLOSED
    }
    enum LoanTenure {
        NONE,
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

    struct User {
        bool hasFile;
        uint256 collateral;
        uint256 loanAmount;
        uint256 monthlyFee;
        uint256 lastPaymentTime;
        uint256 nextPaymentTime;
        address angel;
        uint256 vaultUsed;
        LoanStatus status;
        LoanTenure tenure;
        uint256 loanStartDate;
    }

    mapping(address => mapping(uint256 => AngelInvestor)) public angelInvestors;
    mapping(address => uint256) public nextVaultId;
    mapping(address => uint256) public vaultsCount;
    mapping(address => User) public users;
    mapping(address => bool) public isInvestor;
    mapping(address => bool) public hasLoan;

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
    event MonthlyPaymentMade(address indexed user, uint256 amount);
    event LoanDefaulted(address indexed user, uint256 iGoldSold);
    event LoanClosed(address indexed user);
    event LoanRepaid(address indexed user);
    event CollateralWithdrawn(address indexed user, uint256 amount);
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
        IERC20(islamiToken).approve(iGoldToken, type(uint256).max);
    }

    /* Testing Function */
    function endTesting() external onlyOwner {
        require(isTesting, "Testing period already ended");
        isTesting = false;
        emit TestingPeriodEnded();
    }
    /* Testing Function */

    function setISLAMIaddress(address _new) external onlyOwner{
        require(_new != address(0),"Zero address");
        islamiToken = _new;
    }

    function setiGoldAddress(address _new) external onlyOwner{
        require(_new != address(0),"Zero address");
        iGoldToken = _new;
    }

    function approveISLAMI() external {
        // Approve the iGoldToken contract to spend the caller's ISLAMI tokens
        bool success = IERC20(islamiToken).approve(
            iGoldToken,
            type(uint256).max
        );
        require(success, "ISLAMI approval failed");
    }

    function depositAsAngelInvestor(uint256 amount, uint256 _duration)
        external
    {
        if(isTesting){
            require(amount > testingMinLoanAmount, "Deposit amount must be greater than 0");
        } else{
            require(amount > minLoanAmountDefault, "Deposit amount must be greater than minLoanAmount");
        }
        require(_duration >= 9, "Deposite should be at least for 9 Months");
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
        investor.duration = isTesting? (_duration * 300) + block.timestamp : (_duration * 30 days) + block.timestamp;

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

    function withdrawFromAngelInvestor(uint256 vaultId)
        external
    {
        require(vaultId < nextVaultId[msg.sender], "Invalid vault ID");
        AngelInvestor storage investor = angelInvestors[msg.sender][vaultId];
        require(block.timestamp >= investor.duration, "Withdraw is not yet");

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
        uint256 toBurn = (oneTimeFee * 40) / 100;
        uint256 toFee = (oneTimeFee * 60) / 100;
        require(
            IERC20(islamiToken).transferFrom(user, address(this), oneTimeFee),
            "Fee transfer failed"
        );
        IERC20(islamiToken).transfer(deadWallet, toBurn);
        IERC20(islamiToken).transfer(feeReceiver, toFee);
        users[user].hasFile = true;
        burnedISLAMI += toBurn;
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
        uint256 _iGoldPrice = getiGoldPrice();

        require(!hasLoan[user],"iQrad: User has loan already");

        users[user].loanStartDate = block.timestamp;

        // Calculate the total value of the iGold collateral
        uint256 collateralValue = (collateralAmount * _iGoldPrice) / (1e8);

        // Calculate the maximum loan amount as 70% of the collateral value
        uint256 amount = ((collateralValue * 70) / 100) / (1e2); //(1e2) to handel the decimal difference

        uint256 minLoanAmount = isTesting ? testingMinLoanAmount : minLoanAmountDefault;

        if (tenure == LoanTenure.ONE_YEAR) {
            minLoanAmount = minLoanAmountOneYear;
        } else if (tenure == LoanTenure.TWO_YEARS) {
            minLoanAmount = minLoanAmountTwoYears;
        }

        require(amount >= minLoanAmount, "iQrad: Loan amount is less than minimum required for the duration");

        // Transfer service fee to deadWallet
        IERC20(islamiToken).transferFrom(msg.sender, deadWallet, serviceFee);
        burnedISLAMI += serviceFee;

        require(
            IERC20(usdtToken).balanceOf(address(this)) >= amount,
            "Insufficient USDT in vaults"
        );

        // Select a vault from which to take the loan
        (, uint256 selectedVaultId) = _selectVaultForLoan(amount, tenure);
        (address _angel, ) = _selectVaultForLoan(amount, tenure);
        require(selectedVaultId != 0, "No suitable vault found for loan");

        uint8 _tenure;
        if (tenure == LoanTenure.SIX_MONTHS) {
            _tenure = 6 ;
        } else if (tenure == LoanTenure.ONE_YEAR) {
            _tenure = 12 ;
        } else if (tenure == LoanTenure.TWO_YEARS) {
            _tenure = 24 ;
        }

        uint256 monthlyFee = amount / _tenure;

        // Deduct the loan amount from the selected vault
        AngelInvestor storage investor = angelInvestors[_angel][
            selectedVaultId
        ];
        investor.availableAmount -= amount;

        usdtInLoans += amount;
        usdtVault -= amount;

        users[user].loanAmount = amount;
        users[user].monthlyFee = monthlyFee;
        users[user].lastPaymentTime = block.timestamp;
        users[user].nextPaymentTime = isTesting? block.timestamp + 300 : block.timestamp + oneMonth;
        users[user].vaultUsed = selectedVaultId;
        users[user].angel = _angel;
        users[user].status = LoanStatus.ACTIVE;
        users[user].tenure = tenure;

        hasLoan[user] = true;
        activeLoanUsers.push(user);
        activeLoans++;

        emit LoanTaken(user, amount);
        require(IERC20(usdtToken).transfer(user, amount), "iQrad: USDT transfer error");
    }

    function _selectVaultForLoan(uint256 loanAmount, LoanTenure tenure)
        internal
        view
        returns (address, uint256)
    {
        require(loanAmount > 0, "Loan amount must be greater than zero"); // Ensure loan amount is positive

        // Validate the loan tenure
        uint256 tenureDuration = _getTenureDuration(tenure);
        require(tenureDuration > 0, "Invalid loan tenure"); // Ensure tenure duration is valid

        uint256 earliestEndTime = block.timestamp + tenureDuration;
        uint256 selectedVaultId = 0;
        address selectedInvestorAddress;
        uint256 selectedVaultEndTime = type(uint256).max;

        bool vaultFound = false; // Flag to check if a suitable vault is found

        // Iterate over all investors
        for (uint256 i = 0; i < investors.length; i++) {
            address investorAddress = investors[i];
            uint256 vaultCount = nextVaultId[investorAddress] - 1;

            // Ensure the investor has at least one vault
            require(vaultCount > 0, "Investor has no vaults");

            // Iterate over all vaults for each investor
            for (uint256 vaultId = 1; vaultId <= vaultCount; vaultId++) {
                AngelInvestor storage vault = angelInvestors[investorAddress][vaultId];

                // Check if the vault has enough USDT and the duration is suitable
                if (vault.availableAmount >= loanAmount && vault.duration >= earliestEndTime) {
                    // Select the vault with the earliest end time that meets the criteria
                    if (vault.duration < selectedVaultEndTime) {
                        selectedVaultId = vaultId;
                        selectedVaultEndTime = vault.duration;
                        selectedInvestorAddress = investorAddress;
                        vaultFound = true;
                    }
                }
            }
        }

        require(vaultFound, "No suitable vault found"); // Ensure a suitable vault is found

        return (selectedInvestorAddress, selectedVaultId);
    }

    function getUSDTAmountForLoan(uint256 _collateralAmount) public view returns (uint256 loanAmount){
    
        // Calculate the total value of the iGold collateral
        uint256 collateralValue = (_collateralAmount * iGoldPrice) / (1e8);

        // Calculate the maximum loan amount as 70% of the collateral value
        uint256 amount = ((collateralValue * 70) / 100) / (1e2);

        return(amount);
    }

    function getiGoldPrice() internal returns(uint256){
        uint256 _iGoldPrice = uint256(iGoldc.getIGoldPrice());
        require(_iGoldPrice > 0, "Invalid iGold price");
        iGoldPrice = _iGoldPrice;
        return(_iGoldPrice);
    }

    function _getTenureDuration(LoanTenure tenure) internal view returns (uint256) {
        if (isTesting) {
            // Return adjusted values for testing
            return 15 minutes;
        } else {
            // Normal operation
            return _calculateNormalDuration(tenure);
        }
    }

    function _calculateNormalDuration(LoanTenure tenure) private pure returns (uint256) {
        if (tenure == LoanTenure.SIX_MONTHS) {
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
        require(
            block.timestamp >= users[msg.sender].nextPaymentTime,
            "Too early"
        );
        require(
            IERC20(usdtToken).transferFrom(
                msg.sender,
                address(this),
                user.monthlyFee
            ),
            "Payment failed"
        );

        // Update the state to reflect the payment
        usdtInLoans -= user.monthlyFee;
        usdtVault += user.monthlyFee;
        user.lastPaymentTime = block.timestamp;

        // Calculate the next payment time based on the loan start date
        uint256 monthsSinceStart = (block.timestamp - user.loanStartDate) / 30 days;
        user.nextPaymentTime = user.loanStartDate + (monthsSinceStart + 1) * 30 days;

        // Adjust for testing mode
        if (isTesting) {
            user.nextPaymentTime = block.timestamp + 300; // Or any other logic for testing
        }

        emit MonthlyPaymentMade(msg.sender, users[msg.sender].monthlyFee);

        AngelInvestor storage investor = angelInvestors[user.angel][
            user.vaultUsed
        ];
        investor.availableAmount += user.monthlyFee;

        user.loanAmount -= user.monthlyFee;

        // Check if this is the last payment
        if (user.loanAmount == 0) {
            closeLoan(msg.sender);
        }
    }

    function handleDefault(address _user) public hasActiveLoan(_user) {
        User storage user = users[_user];
        require(
            block.timestamp >= user.nextPaymentTime,
            "Not a default case"
        );

        // Get the current price of iGold in terms of USDT
        uint256 _iGoldPrice = getiGoldPrice() / (1e2);
        require(_iGoldPrice > 0, "Invalid iGold price");

        // Calculate the amount of iGold needed to cover the unpaid monthly fee
        uint256 iGoldNeededForFee = (user.monthlyFee * (1e8)) / _iGoldPrice;

        // Calculate the amount of iGold equivalent to 1 USDT for buffer
        uint256 iGoldEquivalentToOneUsdt = ((1e6) * (1e8)) / _iGoldPrice;

        // Total iGold to sell is the sum of iGoldNeededForFee and iGoldEquivalentToOneUsdt
        uint256 totaliGoldToSell = iGoldNeededForFee + iGoldEquivalentToOneUsdt;

        // Ensure the user has enough iGold collateral to cover the unpaid monthly fee
        require(
            user.collateral >= totaliGoldToSell,
            "Insufficient iGold collateral"
        );

        // Check USDT balance before selling iGold
        uint256 usdtBalanceBefore = IERC20(usdtToken).balanceOf(address(this));

        // Execute the sell function in the iGold contract
        iGoldc.sell(totaliGoldToSell);

         // Check USDT balance after selling iGold
        uint256 usdtBalanceAfter = IERC20(usdtToken).balanceOf(address(this));

        // Calculate the actual USDT received from selling iGold
        uint256 actualUsdtReceived = usdtBalanceAfter - usdtBalanceBefore;

        require(actualUsdtReceived >= user.monthlyFee, "USDT received is less than the monthly fee");

        // Update the iGold and USDT vault balances
        iGoldVault -= totaliGoldToSell;
        usdtInLoans -= user.monthlyFee;
        usdtVault += user.monthlyFee;

        // Calculate the excess USDT after covering the monthly fee
        uint256 excessUsdt = actualUsdtReceived - (user.monthlyFee);

        // Return the 1 USDT buffer excess to the contract owner as fees on the operation
        if (excessUsdt > 0) {
            IERC20(usdtToken).transfer(defaultHandler, excessUsdt);
        }

        // Update investor vault
        AngelInvestor storage investor = angelInvestors[user.angel][
            user.vaultUsed
        ];
        investor.availableAmount += user.monthlyFee;

        // Update the user's iGold collateral and last payment time
        user.collateral -= totaliGoldToSell;
        user.loanAmount -= user.monthlyFee;
        user.lastPaymentTime = block.timestamp;

        // Calculate the next payment time based on the loan start date
        uint256 monthsSinceStart = (block.timestamp - user.loanStartDate) / 30 days;
        user.nextPaymentTime = user.loanStartDate + (monthsSinceStart + 1) * 30 days;

        // Adjust for testing mode
        if (isTesting) {
            user.nextPaymentTime = block.timestamp + 300; // Or any other logic for testing
        }

        // Check if this is the last payment
        if (user.loanAmount == 0) {
            closeLoan(_user);
        } else {
            emit LoanDefaulted(_user, totaliGoldToSell);
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
        user.monthlyFee = 0;
        user.lastPaymentTime = 0;
        user.nextPaymentTime = 0;
        user.vaultUsed = 0;
        user.angel = address(0);
        user.tenure = LoanTenure.NONE;
        user.loanStartDate = 0;

        hasLoan[_user] = false;
        _removeActiveLoanUser(_user);
        activeLoans--;

        emit LoanClosed(_user);
    }

    function repayLoan() external hasActiveLoan(msg.sender) {
        User storage user = users[msg.sender];
        uint256 remainingLoan = user.loanAmount;
        require(
            IERC20(usdtToken).transferFrom(
                msg.sender,
                address(this),
                remainingLoan
            ),
            "Repayment failed"
        );

        // Update investor vault
        AngelInvestor storage investor = angelInvestors[user.angel][
            user.vaultUsed
        ];
        investor.availableAmount += remainingLoan;
        usdtVault += remainingLoan;

        user.loanAmount = 0;
        user.status = LoanStatus.CLOSED;

        // Transfer back the collateral to the user
        uint256 collateral = user.collateral;
        require(
            IERC20(iGoldToken).transfer(msg.sender, collateral),
            "Collateral transfer failed"
        );

        iGoldVault -= collateral;
        usdtInLoans -= remainingLoan;
        user.collateral = 0;
        user.monthlyFee = 0;
        user.lastPaymentTime = 0;
        user.nextPaymentTime = 0;
        user.vaultUsed = 0;
        user.angel = address(0);
        user.tenure = LoanTenure.NONE;
        user.loanStartDate = 0;

        hasLoan[msg.sender] = false;
        _removeActiveLoanUser(msg.sender);

        emit LoanRepaid(msg.sender);
    }

    function withdrawCollateral(uint256 amount) external hasFile(msg.sender) {
        require(
            users[msg.sender].status == LoanStatus.CLOSED,
            "Loan not closed"
        );
        require(
            users[msg.sender].collateral >= amount,
            "Insufficient collateral"
        );

        require(
            IERC20(iGoldToken).transfer(msg.sender, amount),
            "Collateral withdrawal failed"
        );
        users[msg.sender].collateral -= amount;

        emit CollateralWithdrawn(msg.sender, amount);
    }

    function updateOneTimeFee(uint256 newFee) external onlyOwner {
        oneTimeFee = newFee;
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

    function setServiceFee(uint256 _newPercentage) external onlyOwner {
        require(_newPercentage > 0, "Service fee must be greater than zero");
        serviceFee = _newPercentage;
    }

    function setMinLoanAmounts(uint256 _twoYears, uint256 _oneYear, uint256 _default) external onlyOwner {
        minLoanAmountTwoYears = _twoYears * (1e6);
        minLoanAmountOneYear = _oneYear * (1e6);
        minLoanAmountDefault = _default * (1e6);
    }

    function getAllInvestorsVaults()
        external
        view
        returns (InvestorVaults[] memory)
    {
        InvestorVaults[] memory allInvestorVaults = new InvestorVaults[](investors.length);

        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            uint256 vaultCount = nextVaultId[investor];
            AngelInvestor[] memory vaults = new AngelInvestor[](vaultCount);

            for (uint256 j = 0; j < vaultCount; j++) {
                vaults[j] = angelInvestors[investor][j];
            }

            allInvestorVaults[i] = InvestorVaults({
                investor: investor,
                vaults: vaults
            });
        }

        return allInvestorVaults;
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
}

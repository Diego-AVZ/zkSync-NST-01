// SPDX-License-Identifier: MIT

/**
 * @author : Nebula.fi
 * ETH + AVAX + BNB + MATIC
 */

pragma solidity ^0.8.7;
import "../../utils/ChainId.sol";
import "hardhat/console.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract NST01zk is ERC20Upgradeable, OwnableUpgradeable, PausableUpgradeable, ChainId{
    event Mint(address indexed from, uint256 ethIn, uint256 avaxIn, uint256 bnbIn, uint256 maticIn, uint256 indexed amount);
    event Burn(address indexed from, uint256 usdcIn, uint256 indexed amount);
    event FeeWithdrawn(address indexed owner, uint256 amount);
    
    mapping(address => uint256) public feesAccumulated;

    uint256 private constant FEE_SHARE_FOR_OWNER = 20; //20% of the fee share goes to Nebula Team
    uint256 private constant FEE_SHARE_FOR_HOLDERS = 80; //80% of the fee share goes to NST holders

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor () {
        _disableInitializers();
    }

    function initialize() public initializer{
        __ERC20_init("ETH+AVAX+BNB+MATIC", "zkNST01");
        __Ownable_init();
        __Pausable_init();
        tokens = [
            0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4, //[0] => USDC
            0x000000000000000000000000000000000000800A, //[1] => ETH 
            0x6A5279E99CA7786fb13F827Fc1Fb4F61684933d6, //[2] => AVAX
            0x7400793aAd94C8CA801aa036357d10F5Fd0ce08f, //[3] => BNB 
            0x28a487240e4D45CfF4A2980D334CC933B7483842, //[4] => MATIC
            ];

        multipliers = [1e12, 1, 1, 1, 1]; 
        marketCapWeigth = [0, 2500, 2500, 2500, 2500];
        syncswap = ISwapRouter(0x2da10A1e27bF85cEdD8FFb1AbBe97e53391C0295); // SYNCSWAP
        priceFeeds = [ //BUSCAR
            AggregatorV3Interface(0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7) //FALSO
        ];
    }

    /**
     * @notice Returns the price of the NST
      ETH/usdc * 0.25 + AVAX/usdc * 0.25 + BNB/usdc * 0.25 + MATIC/usdc * 0.25
     */
    function getVirtualPrice() public view returns (uint256) {
        return (((getLatestPrice(1) * 2500) / 10000) + ((getLatestPrice(2) * 2500) / 10000)) + ((getLatestPrice(3) * 2500) / 10000) + ((getLatestPrice(4) * 2500) / 10000);
    }

    /**
     * @notice function to buy 25% ETH + 25% AVAX + 25% BNB + 25% MATIC
     * @param tokenIn : the token to deposit, must be a component of the index(0,1,2,3,4)
     * @param amountIn : token amount to deposit
     * @param recipient : recipient of the NST tokens
     * @return shares : amount of minted tokens
     */


    function _calculateFee(uint256 amount, uint256 feePercentage) private pure returns (uint256) {
        return (amount * feePercentage) / 10000;
    }

    function deposit(uint8 tokenIn, uint256 amountIn, address recipient)
        public
        whenNotPaused
        returns (uint256 shares)
    {
        require(tokenIn < 4, "token >=4");
        require(amountIn > 0, "dx=0");
        uint256 dywETH;
        uint256 dywAVAX;
        uint256 dywBNB;
        uint256 dywMATIC;
        uint8 i = tokenIn;

        TransferHelper.safeTransferFrom(tokens[i], msg.sender, address(this), amountIn);

        // antes... (uint256 amountForETH, uint256 amountForAVAX, uint256 amountForBNB, uint256 amountForMATIC) = ((amountIn * 2500) / 10000, (amountIn * 2500) / 10000, (amountIn * 2500) / 10000, (amountIn * 2500) / 10000);
        uint256 feeAmount = _calculateFee(amountIn, 10); //0.1% fee for deposit
        uint256 amountAfterFee = amountIn - feeAmount;
        (uint256 amountForETH, uint256 amountForAVAX, uint256 amountForBNB, uint256 amountForMATIC) = ((amountAfterFee * 2500) / 10000, (amountAfterFee * 2500) / 10000, (amountAfterFee * 2500) / 10000, (amountAfterFee * 2500) / 10000);
        
        approveAMM(i, amountIn);
        dywETH = swapWithParams(i, 1, amountForEth);
        dywAVAX = swapWithParams(i, 2, amountForAVAX);
        dywMATIC = swapWithParams(i, 4, amountForMATIC);
        dywBNB = swapWithParams(i, 3, amountForBNB);
        _mint(
            recipient,
            //REVISAR 'multipliers[]'
            shares = ((dywETH * multipliers[1] * getLatestPrice(1)) + (dywAVAX * multipliers[2] * getLatestPrice(2)) +(dywBNB * multipliers[3] * getLatestPrice(3)) + (dywMATIC * multipliers[4] * getLatestPrice(4)))
                / getVirtualPrice()
        );
        emit Mint(recipient, dywETH, dywAVAX, dywBNB, dywMATIC, shares);
    }

    
    /**
     * @notice Function to liquidate ETH, AVAX, BNB & MATIC positions for usdc
     * @param nstIn : the number of indexed tokens to burn 
     * @param recipient : recipient of the USDC
     * @return usdcOut : final usdc amount to withdraw after slippage and fees
     */
    function withdrawUsdc(uint256 nstIn, address recipient)
        external
        whenNotPaused
        returns (uint256 usdcOut)
    {
        require(nstIn > 0, "dx=0");

        uint256 balanceETH = IERC20(tokens[1]).balanceOf(address(this));
        uint256 balanceAVAX = IERC20(tokens[2]).balanceOf(address(this));
        uint256 balanceBNB = IERC20(tokens[3]).balanceOf(address(this));
        uint256 balanceMATIC = IERC20(tokens[4]).balanceOf(address(this));
        uint256 ethIn = balanceETH * nstIn / totalSupply();
        uint256 avaxIn = balanceAVAX * nstIn / totalSupply();
        uint256 bnbIn = balanceBNB * nstIn / totalSupply();
        uint256 maticIn = balanceMATIC * nstIn / totalSupply();
        
        require(balanceOf(address(this)) >= amount, "insufficient balance");
        uint256 feeAmount = _calculateFee(amount, 15); //0.15% fee for withdrawUsdc 
        uint256 amountAfterFee = amount - feeAmount;

        feesAccumulated[tokens[0]] += _calculateFee(amount, 15); //accumulate fee in USDC token #REVISAR: queremos que se cobre en NST?

        TransferHelper.safeTransfer(tokens[0], recipient, amountAfterFee);

        _burn(msg.sender, nstIn);
        approveAMM(1, ethIn);
        approveAMM(2, avaxIn);
        approveAMM(3, bnbIn);
        approveAMM(4, maticIn);
        
        /* antes... TransferHelper.safeTransfer(
            tokens[0],
            recipient,
            usdcOut = swapWithParams(1, 0, ethIn) + swapWithParams(2, 0, avaxIn) + swapWithParams(3, 0, bnbIn) + swapWithParams(4, 0, maticIn)
                                No entiendo el "0" 
        );*/

        emit Burn(recipient, usdcOut, nstIn);
    }

    function _getTotal(uint16[5] memory _params) private pure returns (uint16) {
        uint256 len = _params.length;
        uint16 total = 0;
        for (uint8 i = 0; i < len;) {
            uint16 n = _params[i];
            if (n != 0) {
                total += n;
            }
            unchecked {
                ++i;
            }
        }
        return total;
    }


    //////////////////////////////////
    // SPECIAL PERMISSION FUNCTIONS//
    /////////////////////////////////

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }  

    function withdrawFees() external onlyOwner {
        uint256 accumulatedFees = feesAccumulated[tokens[0]];
        uint256 feeForOwner = (accumulatedFees * FEE_SHARE_FOR_OWNER) / 100;
        uint256 feeForHolders = (accumulatedFees * FEE_SHARE_FOR_HOLDERS) / 100;

        TransferHelper.safeTransfer(tokens[0], msg.sender, feeForOwner); //transfer owner's share of the fees

        uint256 totalSupply = totalSupply();
        for (uint256 i = 0; i < totalSupply; i++) {
            address holder = tokenHoldersAt(i);
            uint256 holderBalance = balanceOf(holder);
            uint256 feeForHolder = (holderBalance * feeForHolders) / totalSupply;
            TransferHelper.safeTransfer(tokens[0], holder, feeForHolder); //transfer holder's share of the fees
        }
        
        feesAccumulated[tokens[0]] = 0; //reset accumulated fees for the token
}
}

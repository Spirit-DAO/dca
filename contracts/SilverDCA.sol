// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <=0.8.25; // L-04

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";// L-05
import "@openzeppelin/contracts/utils/Strings.sol";
import 'contracts/Libraries/TransferHelper.sol';

import {Utils} from "contracts/Libraries/Utils.sol";
import 'contracts/DcaApprover.sol';

import 'contracts/Integrations/Gelato/AutomateTaskCreator.sol';

interface IProxyParaswap {
	function simpleSwap(Utils.SimpleData memory data) external payable returns (uint256);
	function multiSwap(Utils.SellData memory data) external payable returns (uint256);
	function megaSwap(Utils.MegaSwapSellData memory data) external payable returns (uint256);
}

/// @title SilverSwap DCA Contract
/// @author github.com/SifexPro
/// @notice This contract allows users to create DCA orders on the SilverSwap platform
contract SilverSwapDCA is AutomateTaskCreator, Ownable2Step {
	// Utils variables
	IProxyParaswap public proxy;
	IERC20 public tresory;
	
	// Order variables
	uint256 public ordersCount;
	mapping(uint256 => Order) public ordersById;
	mapping(address => uint256[]) public idByAddress;

	// ParaSwap structs
	struct paraswapArgs {
		Utils.SimpleData simpleData;
		Utils.SellData sellData;
		Utils.MegaSwapSellData megaSwapSellData;
	}

	// Script CID for Gelato
	string private scriptCID = "QmPWpjsLcCQ19zgYquUWh2CUojQAcLuvFyC74bisihUveZ";

	// Events for Orders
	event OrderCreated(address indexed user, uint256 indexed id, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period);
	event OrderEdited(address indexed user, uint256 indexed id, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period);
	event OrderStopped(address indexed user, uint256 indexed id);
	event OrderRestarted(address indexed user, uint256 indexed id);
	event OrderExecuted(address indexed user, uint256 indexed id, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 amountOutMin, uint256 period);

	// Events for GELATO
	event GelatoTaskCreated(bytes32 id);
	event GelatoTaskCancelled(bytes32 id);
	event GelatoFeesCheck(uint256 fees, address token);

	// Events for Misc
	event EditedTresory(address usdc);
	event EditedScriptCID(string cid);
	event WithdrawnFees(address tresory, uint256 amount);

	// Error events
	error ErrorOrderDoesNotExist(uint256 id, uint256 ordersCount);
	error ErrorNotAuthorized(uint id, address user, address msgSender);
	error ErrorInvalidTokens(address tokenIn, address tokenOut);
	error ErrorOrderStopped(uint256 id);
	error ErrorOrderNotStopped(uint256 id);
	error ErrorPeriodNotElapsed(uint256 id, uint256 lastExecution, uint256 blockTimestamp, uint256 nextExecution);
	error ErrorInvalidParaswapArgs();
	error ErrorTaskAlreadyCreated(uint256 id);
	error ErrorTaskNotCreated(uint256 id);

	constructor(address _proxy, address _automate, address _tresory) AutomateTaskCreator(_automate) Ownable(msg.sender) {
		proxy = IProxyParaswap(payable(_proxy));
		tresory = IERC20(_tresory);
	}

	/**
	 * @dev Execute the order (internal function)
	 * @param id the order id
	 * @param dcaArgs the dcaArgs struct for Paraswap execution
	 */
	function _executeOrder(uint id, paraswapArgs memory dcaArgs) private {
		bool isSimpleSwap = !isSimpleDataEmpty(dcaArgs.simpleData);				// G-03
		bool isSellSwap = !isSellDataEmpty(dcaArgs.sellData);					// G-03
		bool isMegaSwap = !isMegaSwapSellDataEmpty(dcaArgs.megaSwapSellData);	// G-03
		//require(isSimpleSwap || isSellSwap || isMegaSwap, 'Invalid dcaArgs');
		if (!isSimpleSwap && !isSellSwap && !isMegaSwap) // G-02
			revert ErrorInvalidParaswapArgs();

		address user = ordersById[id].user;
		IERC20 tokenIn = IERC20(ordersById[id].tokenIn);
		IERC20 tokenOut = IERC20(ordersById[id].tokenOut);

		uint256	fees = ordersById[id].amountIn / 100;
		uint256 amountIn = ordersById[id].amountIn - fees;

		if (isSimpleSwap) {			// G-03
			dcaArgs.simpleData.beneficiary = payable(address(user));
			dcaArgs.simpleData.toToken = ordersById[id].tokenOut;
			dcaArgs.simpleData.fromToken = ordersById[id].tokenIn;
			dcaArgs.simpleData.fromAmount = amountIn;
		} else if (isSellSwap) {	// G-03
			dcaArgs.sellData.beneficiary = payable(address(user));
			dcaArgs.sellData.fromToken = ordersById[id].tokenIn;
			dcaArgs.sellData.fromAmount = amountIn;
		} else if (isMegaSwap) {	// G-03
			dcaArgs.megaSwapSellData.beneficiary = payable(address(user));
			dcaArgs.megaSwapSellData.fromToken = ordersById[id].tokenIn;
			dcaArgs.megaSwapSellData.fromAmount = amountIn;
		}

		uint256 balanceBefore = tokenOut.balanceOf(user);
		ordersById[id].totalExecutions += 1;
		ordersById[id].totalAmountIn += amountIn;
        SilverDcaApprover(ordersById[id].approver).executeOrder();
		ordersById[id].lastExecution = block.timestamp;
		
		require(tokenIn.transfer(address(tresory), fees), 'Failed to transfer fees'); // L-03 
		TransferHelper.safeApprove(address(tokenIn), address(proxy), amountIn); // L-06
		//tokenIn.approve(address(proxy), amountIn);
		if (isSimpleSwap)		// G-03
			proxy.simpleSwap(dcaArgs.simpleData);
		else if (isSellSwap)	// G-03
			proxy.multiSwap(dcaArgs.sellData);
		else if (isMegaSwap)	// G-03
			proxy.megaSwap(dcaArgs.megaSwapSellData);
		
		uint256 balanceAfter = tokenOut.balanceOf(user);
		uint256 amountOutMin = ordersById[id].amountOutMin; // G-06
		uint amountOut = balanceAfter - balanceBefore;	// G-06

		require(amountOut >= amountOutMin, 'Too little received');
		ordersById[id].totalAmountOut += amountOut;

		uint256 period = ordersById[id].period; //G-06
		emit OrderExecuted(user, id, address(tokenIn), address(tokenOut), amountIn, amountOut, amountOutMin, period);
	}
	
	/**
	 * @dev Execute the order (public function)
	 * @param id the order id
	 * @param amountTokenInGelatoFees the amount of token to pay (in tokenIn) for Gelato fees
	 * @param dcaArgs the dcaArgs struct for Paraswap execution
	 * @param ftmSwapArgs the ftmSwapArgs struct for Paraswap execution (for Gelato fees)
	 */
	function executeOrder(uint256 id, uint256 amountTokenInGelatoFees, paraswapArgs memory dcaArgs, paraswapArgs memory ftmSwapArgs) public onlyOwnerOrDedicatedMsgSender { // H-03 (onlyOwnerOrDedicatedMsgSender)
		//require(id < getOrdersCountTotal(), 'Order does not exist');
		if (id >= getOrdersCountTotal()) // G-02
			revert ErrorOrderDoesNotExist(id, getOrdersCountTotal());
		//require(ordersById[id].stopped == false, 'Order is stopped');
		if (ordersById[id].stopped) // G-02
			revert ErrorOrderStopped(id);
		//require(block.timestamp - ordersById[id].lastExecution >= ordersById[id].period, 'Period not elapsed');
		if (block.timestamp - ordersById[id].lastExecution < ordersById[id].period) // G-02
			revert ErrorPeriodNotElapsed(id, ordersById[id].lastExecution, block.timestamp, ordersById[id].lastExecution + ordersById[id].period);
		require(ERC20(ordersById[id].tokenIn).balanceOf(ordersById[id].user) >= ordersById[id].amountIn, 'Not enough balance');

		uint256 initialAmountIn = ordersById[id].amountIn;
		bool isSimpleSwap = !isSimpleDataEmpty(ftmSwapArgs.simpleData);				// G-03
		bool isSellSwap = !isSellDataEmpty(ftmSwapArgs.sellData);					// G-03
		bool isMegaSwap = !isMegaSwapSellDataEmpty(ftmSwapArgs.megaSwapSellData);	// G-03
		bool isFtmSwap = isSimpleSwap || isSellSwap || isMegaSwap;

		if (isFtmSwap)
		{
			uint256 gelatoFees = 0;

			require(amountTokenInGelatoFees < ordersById[id].amountIn, 'amountTokenInGelatoFees too high');
			ordersById[id].amountIn -= amountTokenInGelatoFees;

			if (isSimpleSwap)		// G-03
				gelatoFees = ftmSwapArgs.simpleData.fromAmount;
			else if (isSellSwap)	// G-03
				gelatoFees = ftmSwapArgs.sellData.fromAmount;
			else if (isMegaSwap)	// G-03
				gelatoFees = ftmSwapArgs.megaSwapSellData.fromAmount;

			SilverDcaApprover(ordersById[id].approver).transferGelatoFees(gelatoFees);
			TransferHelper.safeApprove(ordersById[id].tokenIn, address(proxy), gelatoFees); // L-06
			//ERC20(ordersById[id].tokenIn).approve(address(proxy), gelatoFees);
			if (isSimpleSwap)		// G-03
				proxy.simpleSwap(ftmSwapArgs.simpleData);
			else if (isSellSwap)	// G-03
				proxy.multiSwap(ftmSwapArgs.sellData);
			else if (isMegaSwap)	// G-03
				proxy.megaSwap(ftmSwapArgs.megaSwapSellData);
		}

		_executeOrder(id, dcaArgs);

		if (isFtmSwap)
		{
			ordersById[id].amountIn = initialAmountIn;
			(uint256 fee, address feeToken) = _getFeeDetails();

        	_transfer(fee, feeToken);
			emit GelatoFeesCheck(fee, feeToken);
		}
	}

	/**
	 * @dev Create an order
	 * @param tokenIn the token to swap
	 * @param tokenOut the token to receive
	 * @param amountIn the amount of tokenIn to swap
	 * @param amountOutMin the minimum amount of tokenOut to receive
	 * @param period the period between each swap
	 * @param dcaArgs the dcaArgs struct for Paraswap execution
	 */
	function createOrder(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 period, paraswapArgs memory dcaArgs) public onlyValidEntries(period, amountIn, amountOutMin) onlyValidTokens(tokenIn, tokenOut){
        address approver = address(new SilverDcaApprover{salt: bytes32(ordersCount)}(ordersCount, msg.sender, tokenIn));
		Order memory order = Order(msg.sender, tokenIn, tokenOut, amountIn, amountOutMin, period, 0, 0, 0, 0, block.timestamp, false, approver, 0);
		ordersById[ordersCount] = order;
		idByAddress[msg.sender].push(ordersCount);
		ordersCount++;

		_executeOrder(getOrdersCountTotal() - 1, dcaArgs);
		createTask(getOrdersCountTotal() - 1);

		emit OrderCreated(msg.sender, getOrdersCountTotal() - 1, tokenIn, tokenOut, amountIn, amountOutMin, period);
	}

	/**
	 * @dev Edit an order
	 * @param id the order id
	 * @param amountIn the amount of tokenIn to swap
	 * @param amountOutMin the minimum amount of tokenOut to receive
	 * @param period the period between each swap
	 * @param dcaArgs the dcaArgs struct for Paraswap execution
	 */
	function editOrder(uint256 id, uint256 amountIn, uint256 amountOutMin, uint256 period, paraswapArgs memory dcaArgs) public onlyUser(id) onlyValidEntries(period, amountIn, amountOutMin) {
		ordersById[id].amountIn = amountIn;
		ordersById[id].amountOutMin = amountOutMin;
		ordersById[id].period = period;
		if (!ordersById[id].stopped && block.timestamp - ordersById[id].lastExecution >= ordersById[id].period) 
			_executeOrder(id, dcaArgs);
		if (!ordersById[id].stopped)
			createTask(id);

		address tokenIn = ordersById[id].tokenIn; // G-06
		address tokenOut = ordersById[id].tokenOut;	// G-06
		emit OrderEdited(msg.sender, id, tokenIn, tokenOut, amountIn, amountOutMin, period);
	}

	/**
	 * @dev Stop an order
	 * @param id the order id
	 */
	function stopOrder(uint256 id) public onlyUser(id){
		//require(ordersById[id].stopped == false, 'Order is already stopped.');
		if (ordersById[id].stopped) // G-02
			revert ErrorOrderStopped(id);

		ordersById[id].stopped = true;
		cancelTask(id);

		emit OrderStopped(msg.sender, id);
	}
	
	/**
	 * @dev Restart an order
	 * @param id the order id
	 * @param dcaArgs the dcaArgs struct for Paraswap execution (in case the order should be directly executed)
	 */
	function restartOrder(uint256 id, paraswapArgs memory dcaArgs) public onlyUser(id) {
		//require(ordersById[id].stopped == true, 'Order is not stopped');
		if (!ordersById[id].stopped) // G-02
			revert ErrorOrderNotStopped(id);

		ordersById[id].stopped = false;
		if (block.timestamp - ordersById[id].lastExecution >= ordersById[id].period) {
			_executeOrder(id, dcaArgs);
		}
		createTask(id);

		emit OrderRestarted(msg.sender, id);
	}


	// Gelato functions

	/**
	 * @dev Create a task with Gelato
	 * Cancel the previous task if it exists
	 * @param id the order id
	 */
	function createTask(uint256 id) private {
		if (ordersById[id].taskId != bytes32(""))
			cancelTask(id);

		bytes memory execData = abi.encode( // H-01 (amount)
			Strings.toHexString(uint256(uint160(address(this))), 20),						//dca
			id,																				//id
			Strings.toHexString((uint256(uint160(ordersById[id].user))), 20),				//userAddress
			Strings.toHexString((uint256(uint160(ordersById[id].tokenIn))), 20),			//srcToken
			Strings.toHexString((uint256(uint160(ordersById[id].tokenOut))), 20),			//destToken
			Strings.toString(ERC20(ordersById[id].tokenIn).decimals()),						//srcDecimals
			Strings.toString(ERC20(ordersById[id].tokenOut).decimals()),					//destDecimals
			Strings.toString((ordersById[id].amountIn * 99) / 100),							//amount
			"250",																			//network
			"spiritswap",																	//partner -> need to be changed (silverswap)
			"false",																		//otherExchangePrices
			"15"																			//maxImpact
		);

		ModuleData memory moduleData = ModuleData({
			modules: new Module[](3),
			args: new bytes[](3)
		});

		moduleData.modules[0] = Module.PROXY;
		moduleData.modules[1] = Module.WEB3_FUNCTION;
		moduleData.modules[2] = Module.TRIGGER;
	
		moduleData.args[0] = _proxyModuleArg();
		moduleData.args[1] = _web3FunctionModuleArg(
			scriptCID,
			execData
		);
		moduleData.args[2] = _timeTriggerModuleArg(
			uint128(ordersById[id].lastExecution), 
			uint128(ordersById[id].period + 180) * 1000
		);

		bytes32 taskId = _createTask(address(this), execData, moduleData, 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
	
		ordersById[id].taskId = taskId;
		
		emit GelatoTaskCreated(taskId);
	}

	/**
	 * @dev Cancel a task with Gelato
	 * @param id the order id
	 */
	function cancelTask(uint256 id) private {
		if (ordersById[id].taskId != bytes32(""))
		{
			bytes32 taskId = ordersById[id].taskId;
			ordersById[id].taskId = bytes32("");

			_cancelTask(taskId);

			emit GelatoTaskCancelled(taskId);
		}
    }


	// Utils functions

	function isSimpleDataEmpty(Utils.SimpleData memory _simpleData) pure private returns (bool) {
		return _simpleData.fromToken == address(0) || _simpleData.toToken == address(0) || _simpleData.fromAmount == 0 || _simpleData.toAmount == 0 || _simpleData.beneficiary == address(0);
	}

	function isSellDataEmpty(Utils.SellData memory _sellData) pure private returns (bool) {
		return _sellData.fromToken == address(0) || _sellData.fromAmount == 0 || _sellData.toAmount == 0 || _sellData.beneficiary == address(0) || _sellData.path.length == 0;
	}

	function isMegaSwapSellDataEmpty(Utils.MegaSwapSellData memory _megaSwapSellData) pure private returns (bool) {
		return _megaSwapSellData.fromToken == address(0) || _megaSwapSellData.fromAmount == 0 || _megaSwapSellData.toAmount == 0 || _megaSwapSellData.beneficiary == address(0) || _megaSwapSellData.path.length == 0;
	}

	function getOrdersCountTotal() public view returns (uint256) {
		return ordersCount;
	}

    function getOrdersCountByAddress(address user) public view returns (uint256) {
        return idByAddress[user].length;
    }

	function getOrdersByIndex(address user, uint256 index) public view returns (Order memory, uint256 id) {
        return (ordersById[idByAddress[user][index]], idByAddress[user][index]);
    }

    function getApproveBytecode(uint256 _id, address _user, address _tokenIn) public pure returns (bytes memory) {
        bytes memory bytecode = type(SilverDcaApprover).creationCode;

        return abi.encodePacked(bytecode, abi.encode(_id, _user, _tokenIn));
    }

    function getApproveAddress(address _user, address _tokenIn) public view returns (address) {
        uint _id = ordersCount;
        bytes memory bytecode = getApproveBytecode(_id, _user, _tokenIn);

        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), _id, keccak256(bytecode))
        );

        // NOTE: cast last 20 bytes of hash to address
        return address(uint160(uint(hash)));
    }


	// Internal functions 

	/**
	 * @dev Edit the tresory address
	 */
	function editTresory(address _tresory) public onlyOwner {
		tresory = IERC20(_tresory);

		emit EditedTresory(_tresory);
	}

	/**
	 * @dev Edit the script CID
	 */
	function editScriptCID(string memory _cid) public onlyOwner {
		scriptCID = _cid;

		emit EditedScriptCID(_cid);
	}

	/**
	 * @dev Withdraw fees (FTM) from the contract
	 */
	function withdrawFees() public onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, 'No FTM to withdraw');

		address _tresory = address(tresory); // G-06
		payable(_tresory).transfer(balance);

		emit WithdrawnFees(_tresory, balance);
    }


	// Modifiers 

	modifier onlyOwnerOrDedicatedMsgSender() { // H-03
		require(msg.sender == owner() || msg.sender == dedicatedMsgSender, 'Not authorized');
		_;
	}
	
	modifier onlyUser(uint256 id) { // G-04
		//require(id < getOrdersCountTotal(), 'Order does not exist');
		if (id >= getOrdersCountTotal()) // G-02
			revert ErrorOrderDoesNotExist(id, getOrdersCountTotal());
		//require(ordersById[id].user == msg.sender, 'Not authorized');
		if (ordersById[id].user != msg.sender) // G-02
			revert ErrorNotAuthorized(id, ordersById[id].user, msg.sender);
		_;
	}

	modifier onlyValidEntries(uint256 period, uint256 amountIn, uint256 amountOutMin) { //G-04
		// No G-02, because seems better to have a revert message for users
		//require(period >= 1 days, 'Period must be > 1 day');
		require(amountIn >= 100, 'AmountIn must be > 99'); // H-02
		require(amountOutMin > 0, 'AmountOutMin must be > 0'); // L-02
		_;
	}

	modifier onlyValidTokens(address tokenIn, address tokenOut) { // G-04
		if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) // G-02
			revert ErrorInvalidTokens(tokenIn, tokenOut);
		_;
	}


	// Receive function (to receive FTM)

	receive() external payable {}
}
// H-01 fixed
// H-02 fixed
// H-03 fixed

// L-01 fixed
// L-02 fixed
// L-03 fixed
// L-04 fixed
// L-05 fixed
// L-06 fixed

// G-01 fixed
// G-02 fixed
// G-03 fixed
// G-04 fixed -> maybe some more modifiers ?
// G-05 fixed (don't need)
// G-06 fixed
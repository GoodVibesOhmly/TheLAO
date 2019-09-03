pragma solidity 0.5.3;

// WIP - please make comments through PRs! 

// Purpose: The LAO is designed to streamline the funding of Ethereum ventures with legal security.

// Code is currently in testing // please review carefully before deploying for your own purposes!

import "./oz/SafeMath.sol";
import "./oz/IERC20.sol";
import "./GuildBank.sol";

contract VentureMoloch {
	using SafeMath for uint256;

	/***************
	GLOBAL CONSTANTS
	***************/
	uint256 public periodDuration; // default = 17280 = 4.8 hours in seconds (5 periods per day)
	uint256 public votingPeriodLength; // default = 35 periods (7 days)
	uint256 public gracePeriodLength; // default = 35 periods (7 days)
	uint256 public abortWindow; // default = 5 periods (1 day)
	uint256 public dilutionBound; // default = 3 - maximum multiplier a YES voter will be obligated to pay in case of mass ragequit
	uint256 public summoningTime; // needed to determine the current period
    
	address private summoner; // Moloch summoner address reference for certain admin controls;
    
	IERC20 public contributionToken; // contribution token contract reference
	IERC20 private tributeToken; // tribute token contract reference 
	GuildBank public guildBank; // guild bank contract reference

	// HARD-CODED LIMITS
	// These numbers are quite arbitrary; they are small enough to avoid overflows when doing calculations
	// with periods or shares, yet big enough to not limit reasonable use cases.
	uint256 constant MAX_VOTING_PERIOD_LENGTH = 10**18; // maximum length of voting period
	uint256 constant MAX_GRACE_PERIOD_LENGTH = 10**18; // maximum length of grace period
	uint256 constant MAX_DILUTION_BOUND = 10**18; // maximum dilution bound
	uint256 constant MAX_NUMBER_OF_SHARES = 10**18; // maximum number of shares that can be minted

	/***************
	EVENTS
	***************/
	event SubmitProposal(
	    uint256 proposalIndex, 
	    address indexed delegateKey, 
	    address indexed memberAddress, 
	    address indexed applicant, 
	    uint256 tributeAmount, 
	    IERC20 tributeToken, 
	    uint256 sharesRequested, 
	    uint256 fundsRequested,
	    string details);
	event SubmitVote(
	    uint256 indexed proposalIndex, 
	    address indexed delegateKey, 
	    address indexed memberAddress, 
	    uint8 uintVote);
	event ProcessProposal(
	        uint256 indexed proposalIndex,
	        address indexed memberAddress, 
	        address indexed applicant, 
	        uint256 tributeAmount,
	        IERC20 tributeToken,
	        uint256 sharesRequested,
	        uint256 fundsRequested,
	        string details,
        	bool didPass);
	event Ragequit(address indexed memberAddress);
	event Abort(uint256 indexed proposalIndex, address applicantAddress);
	event UpdateDelegateKey(address indexed memberAddress, address newDelegateKey);
	event SummonComplete(address indexed summoner, uint256 shares);

	/******************
	INTERNAL ACCOUNTING
	******************/
	uint256 public totalShares = 0; // total shares across all members
	uint256 public totalSharesRequested = 0; // total shares that have been requested in unprocessed proposals
	
	// guild bank accounting in base contribution token
	uint256 public totalContributed = 0; // total member contributions to guild bank
	uint256 public totalDividends = 0; // total dividends that may be claimed by members from guild bank
	uint256 public totalWithdrawals = 0; // total member and funding withdrawals from guild bank
	
	enum Vote {
    	Null, // default value, counted as abstention
    	Yes,
    	No
	}
	
	/*
    	Add-on terms from original Moloch Code: 
		-uint256 tributeAmount,
		-uint256 lastTotalDividends
    */
	struct Member {
    	address delegateKey; // the key responsible for submitting proposals and voting - defaults to member address unless updated
    	uint256 shares; // the # of shares assigned to this member
    	bool exists; // always true once a member has been created
    	uint256 tributeAmount; // amount contributed by member to guild bank (determines fair share)
    	uint256 highestIndexYesVote; // highest proposal index # on which the member voted YES
    	uint256 lastTotalDividends; // tally of member dividend withdrawals
	}
	
    /*
    	Add-on terms from original Moloch Code: 
		-IERC20 tributeToken,
		-uint256 fundsRequested
    */
	struct Proposal {
    	address proposer; // the member who submitted the proposal
    	address applicant; // the applicant who wishes to become a member - this key will be used for withdrawals
    	uint256 tributeAmount; // amount of tokens offered as tribute
    	IERC20 tributeToken; // the tribute token reference for subscription or alternative contribution
    	uint256 sharesRequested; // the # of shares the applicant is requesting
    	uint256 fundsRequested; // the funds requested for applicant 
    	string details; // proposal details - could be IPFS hash, plaintext, or JSON
    	uint256 startingPeriod; // the period in which voting can start for this proposal
    	uint256 yesVotes; // the total number of YES votes for this proposal
    	uint256 noVotes; // the total number of NO votes for this proposal
    	bool processed; // true only if the proposal has been processed
    	bool didPass; // true only if the proposal passed
    	bool aborted; // true only if applicant calls "abort" before end of voting period
    	uint256 maxTotalSharesAtYesVote; // the maximum # of total shares encountered at a yes vote on this proposal
    	mapping (address => Vote) votesByMember; // the votes on this proposal by each member
	}

	mapping (address => Member) public members;
	mapping (address => address) public memberAddressByDelegateKey;
	Proposal[] public ProposalQueue;

	/********
	MODIFIERS
	********/ 
	//onlySummoner is add-on to original Moloch Code. Allows summoner to act as administrator for guild bank.  
	modifier onlySummoner {
    	require(msg.sender == summoner, "Moloch:onlySummoner - not the summoner");
    	_;
	}
    
	modifier onlyMember {
    	require(members[msg.sender].shares > 0, "Moloch::onlyMember - not a member");
    	_;
	}

	modifier onlyDelegate {
    	require(members[memberAddressByDelegateKey[msg.sender]].shares > 0, "Moloch::onlyDelegate - not a delegate");
    	_;
	}

	/********
	FUNCTIONS
	********/
	constructor(
    	address _summoner,
    	address _contributionToken,
    	uint256 _periodDuration,
    	uint256 _votingPeriodLength,
    	uint256 _gracePeriodLength,
    	uint256 _abortWindow,
    	uint256 _dilutionBound
	) public {
    	require(_summoner != address(0), "Moloch::constructor - summoner cannot be 0");
    	require(_contributionToken != address(0), "Moloch::constructor - _contributionToken cannot be 0");
    	require(_periodDuration > 0, "Moloch::constructor - _periodDuration cannot be 0");
    	require(_votingPeriodLength > 0, "Moloch::constructor - _votingPeriodLength cannot be 0");
    	require(_votingPeriodLength <= MAX_VOTING_PERIOD_LENGTH, "Moloch::constructor - _votingPeriodLength exceeds limit");
    	require(_gracePeriodLength <= MAX_GRACE_PERIOD_LENGTH, "Moloch::constructor - _gracePeriodLength exceeds limit");
    	require(_abortWindow > 0, "Moloch::constructor - _abortWindow cannot be 0");
    	require(_abortWindow <= _votingPeriodLength, "Moloch::constructor - _abortWindow must be smaller than or equal to _votingPeriodLength");
    	require(_dilutionBound > 0, "Moloch::constructor - _dilutionBound cannot be 0");
    	require(_dilutionBound <= MAX_DILUTION_BOUND, "Moloch::constructor - _dilutionBound exceeds limit");

    	summoner = _summoner;
    	
    	// contribution token is the base token for guild bank accounting
    	contributionToken = IERC20(_contributionToken);

    	guildBank = new GuildBank(_contributionToken);

    	periodDuration = _periodDuration;
    	votingPeriodLength = _votingPeriodLength;
    	gracePeriodLength = _gracePeriodLength;
    	abortWindow = _abortWindow;
    	dilutionBound = _dilutionBound;

    	summoningTime = now;

    	members[summoner] = Member(summoner, 1, true, 0, 0, 0);
    	memberAddressByDelegateKey[summoner] = summoner;
    	totalShares = 1;

    	emit SummonComplete(summoner, 1);
	}

	/*****************
	PROPOSAL FUNCTIONS
	*****************/
	function submitProposal(
    	address applicant,
    	uint256 tributeAmount,
    	IERC20 _tributeToken,
    	uint256 sharesRequested,
    	uint256 fundsRequested,
    	string memory details
	)
    	public
    	onlyDelegate
	{
    	require(applicant != address(0), "Moloch::submitProposal - applicant cannot be 0");

    	// Make sure we won't run into overflows when doing calculations with shares.
    	// Note that totalShares + totalSharesRequested + sharesRequested is an upper bound
    	// on the number of shares that can exist until this proposal has been processed.
    	require(totalShares.add(totalSharesRequested).add(sharesRequested) <= MAX_NUMBER_OF_SHARES, "Moloch::submitProposal - too many shares requested");
    	
    	totalSharesRequested = totalSharesRequested.add(sharesRequested);

    	address memberAddress = memberAddressByDelegateKey[msg.sender];
    	
    	tributeToken = IERC20(_tributeToken);
    	
        // collect token tribute from applicant and store it in the Moloch until the proposal is processed
    	require(tributeToken.transferFrom(applicant, address(this), tributeAmount), "Moloch::submitProposal - tribute token transfer failed");
    	
    	// compute startingPeriod for proposal
    	uint256 startingPeriod = max(
        	getCurrentPeriod(),
        	ProposalQueue.length == 0 ? 0 : ProposalQueue[ProposalQueue.length.sub(1)].startingPeriod
    	).add(1);

    	// create proposal ...
    	Proposal memory proposal = Proposal({
        	proposer: memberAddress,
        	applicant: applicant,
        	tributeAmount: tributeAmount,
        	tributeToken: tributeToken,
        	sharesRequested: sharesRequested,
        	fundsRequested: fundsRequested,
        	details: details,
        	startingPeriod: startingPeriod,
        	yesVotes: 0,
        	noVotes: 0,
        	processed: false,
        	didPass: false,
        	aborted: false,
        	maxTotalSharesAtYesVote: 0
    	});

    	// ... and append it to the queue
    	ProposalQueue.push(proposal);

    	uint256 proposalIndex = ProposalQueue.length.sub(1);
    	emit SubmitProposal(
    	    proposalIndex, 
    	    msg.sender, 
    	    memberAddress, 
    	    applicant, 
    	    tributeAmount,
    	    tributeToken,
    	    sharesRequested,
    	    fundsRequested,
    	    details);
	}
    
	function submitVoteonProposal(uint256 proposalIndex, uint8 uintVote) public onlyDelegate {
    	address memberAddress = memberAddressByDelegateKey[msg.sender];
    	Member storage member = members[memberAddress];

    	require(proposalIndex < ProposalQueue.length, "Moloch::submitVote - proposal does not exist");
    	Proposal storage proposal = ProposalQueue[proposalIndex];

    	require(uintVote < 3, "Moloch::submitVote - uintVote must be less than 3");
    	Vote vote = Vote(uintVote);

    	require(getCurrentPeriod() >= proposal.startingPeriod, "Moloch::submitVote - voting period has not started");
    	require(!hasVotingPeriodExpired(proposal.startingPeriod), "Moloch::submitVote - proposal voting period has expired");
    	require(proposal.votesByMember[memberAddress] == Vote.Null, "Moloch::submitVote - member has already voted on this proposal");
    	require(vote == Vote.Yes || vote == Vote.No, "Moloch::submitVote - vote must be either Yes or No");
    	require(!proposal.aborted, "Moloch::submitVote - proposal has been aborted");

    	// store vote
    	proposal.votesByMember[memberAddress] = vote;

    	// count vote
    	if (vote == Vote.Yes) {
        	proposal.yesVotes = proposal.yesVotes.add(member.shares);

        	// set highest index (latest) yes vote - must be processed for member to ragequit
        	if (proposalIndex > member.highestIndexYesVote) {
            	member.highestIndexYesVote = proposalIndex;
        	}

        	// set maximum of total shares encountered at a yes vote - used to bound dilution for yes voters
        	if (totalShares > proposal.maxTotalSharesAtYesVote) {
            	proposal.maxTotalSharesAtYesVote = totalShares;
        	}

    	} else if (vote == Vote.No) {
        	proposal.noVotes = proposal.noVotes.add(member.shares);
    	}

    	emit SubmitVote(proposalIndex, msg.sender, memberAddress, uintVote);
	}

	function processProposal(uint256 proposalIndex) public {
    	require(proposalIndex < ProposalQueue.length, "Moloch::processProposal - proposal does not exist");
    	Proposal storage proposal = ProposalQueue[proposalIndex];

    	require(getCurrentPeriod() >= proposal.startingPeriod.add(votingPeriodLength).add(gracePeriodLength),"Moloch::processProposal - proposal is not ready to be processed");
    	require(proposal.processed == false, "Moloch::processProposal - proposal has already been processed");
    	require(proposalIndex == 0 || ProposalQueue[proposalIndex.sub(1)].processed, "Moloch::processProposal - previous proposal must be processed");

    	proposal.processed = true;
    	totalSharesRequested = totalSharesRequested.sub(proposal.sharesRequested);
    	
    	bool didPass = proposal.yesVotes > proposal.noVotes;

    	// Make the proposal fail if the dilutionBound is exceeded
    	if (totalShares.mul(dilutionBound) < proposal.maxTotalSharesAtYesVote) {
        	didPass = false;
    	}

    	// PROPOSAL PASSED
    	if (didPass && !proposal.aborted) {

        	proposal.didPass = true;

        	// if the applicant is already a member, add to their existing shares
        	if (members[proposal.applicant].exists) {
            	members[proposal.applicant].shares = members[proposal.applicant].shares.add(proposal.sharesRequested);
                if (proposal.tributeToken == contributionToken) {
            	    members[proposal.applicant].tributeAmount = members[proposal.applicant].tributeAmount.add(proposal.tributeAmount);
                }

        	// the applicant is a new member, create a new record for them
        	} else {
            	// if the applicant address is already taken by a member's delegateKey, reset it to their member address
            	if (members[memberAddressByDelegateKey[proposal.applicant]].exists) {
                	address memberToOverride = memberAddressByDelegateKey[proposal.applicant];
                	memberAddressByDelegateKey[memberToOverride] = memberToOverride;
                	members[memberToOverride].delegateKey = memberToOverride;
            	}

            	// use applicant address as delegateKey by default
            	members[proposal.applicant] = Member(proposal.applicant, proposal.sharesRequested, true, 0, 0, 0);
            	    if (proposal.tributeToken == contributionToken) {
            	    	members[proposal.applicant] = Member(proposal.applicant, proposal.sharesRequested, true, proposal.tributeAmount, 0, 0);
            	}
            	memberAddressByDelegateKey[proposal.applicant] = proposal.applicant;
        	}

        	// mint new shares
        	totalShares = totalShares.add(proposal.sharesRequested);
        	
        	// update total member contribution tally if tribute amount in contribution token
            if (proposal.tributeToken == contributionToken) {
        	totalContributed = totalContributed.add(proposal.tributeAmount);
            }
            
            // update total guild bank withdrawal tally to reflect requested funds disbursement 
        	totalWithdrawals = totalWithdrawals.add(proposal.fundsRequested);
        	
        	// transfer token tribute to guild bank
        	require(
            	proposal.tributeToken.transfer(address(guildBank), proposal.tributeAmount),
            	"Moloch::processProposal - token transfer to guild bank failed"
        	);
        	 
        	// instruct guild bank to transfer requested funds to applicant address
        	require(
            	guildBank.withdrawFunds(proposal.applicant, proposal.fundsRequested),
            	"Moloch::ragequit - withdrawal of tokens from guildBank failed"
        	);
       	 
    	// PROPOSAL FAILED OR ABORTED
    	} else {
        	// return all tribute tokens to the applicant
        	require(
            	proposal.tributeToken.transfer(proposal.applicant, proposal.tributeAmount),
            	"Moloch::processProposal - failing vote token transfer failed"
        	);
    	}

    	emit ProcessProposal(
        	proposalIndex,
        	proposal.proposer,
        	proposal.applicant,
        	proposal.tributeAmount,
        	proposal.tributeToken,
        	proposal.sharesRequested,
        	proposal.fundsRequested,
        	proposal.details,
        	didPass
    	);
	}
    
	function ragequit() public onlyMember {
    	Member storage member = members[msg.sender];

    	require(canRagequit(member.highestIndexYesVote), "Moloch::ragequit - cant ragequit until highest index proposal member voted YES on is processed");
    	
    	// TO-DO // revise fair share withdrawalAmount with safeMath
    	//uint256 withdrawalAmount = (member.tributeAmount / totalContributed) * ((totalContributed + totalDividends) - totalWithdrawals);
    	//TODO - test w/ SafeMath
    	uint256 withdrawalAmount = (member.tributeAmount.div(totalContributed)).mul(totalContributed.add(totalDividends)).sub(totalWithdrawals);
    	// burn shares and other pertinent membership records
    	totalShares = totalShares.sub(member.shares);
    	member.shares = 0;
    	member.tributeAmount = 0; 
    	member.lastTotalDividends = 0;
    	
    	totalWithdrawals = totalWithdrawals.add(withdrawalAmount); // update total guild bank withdrawal tally to reflect raqequit amount

    	// instruct guild bank to transfer withdrawal amount to ragequitter
    	require(
        	guildBank.withdraw(msg.sender, withdrawalAmount),
        	"Moloch::ragequit - withdrawal of tokens from guildBank failed"
    	);

    	emit Ragequit(msg.sender);
	}
	
	/*
		An applicant can cancel their proposal within Moloch voting grace period.
		Any tribute amount put up for membership and/or guild bank funding will then be returned.
	*/
	function abortProposal(uint256 proposalIndex) public {
    	require(proposalIndex < ProposalQueue.length, "Moloch::abort - proposal does not exist");
    	Proposal storage proposal = ProposalQueue[proposalIndex];

    	require(msg.sender == proposal.applicant, "Moloch::abort - msg.sender must be applicant");
    	require(getCurrentPeriod() < proposal.startingPeriod.add(abortWindow), "Moloch::abort - abort window must not have passed");
    	require(!proposal.aborted, "Moloch::abort - proposal must not have already been aborted");

    	uint256 tokensToAbort = proposal.tributeAmount;
    	proposal.tributeAmount = 0;
    	proposal.aborted = true;

    	// return all tribute tokens to the applicant
    	require(
        	proposal.tributeToken.transfer(proposal.applicant, tokensToAbort),
        	"Moloch::abort- failed to return tribute to applicant"
    	);

    	emit Abort(proposalIndex, msg.sender);
	}

	function updateDelegateKey(address newDelegateKey) public onlyMember {
    	require(newDelegateKey != address(0), "Moloch::updateDelegateKey - newDelegateKey cannot be 0");

    	// skip checks if member is setting the delegate key to their member address
    	if (newDelegateKey != msg.sender) {
        	require(!members[newDelegateKey].exists, "Moloch::updateDelegateKey - cant overwrite existing members");
        	require(!members[memberAddressByDelegateKey[newDelegateKey]].exists, "Moloch::updateDelegateKey - cant overwrite existing delegate keys");
    	}

    	Member storage member = members[msg.sender];
    	memberAddressByDelegateKey[member.delegateKey] = address(0);
    	memberAddressByDelegateKey[newDelegateKey] = msg.sender;
    	member.delegateKey = newDelegateKey;

    	emit UpdateDelegateKey(msg.sender, newDelegateKey);
	}
	
	// Extension to original Moloch Code: allows a Member to withdraw any dividends declared by summoner admin
	function claimDividend() public onlyMember {
        Member storage member = members[msg.sender];

    	// claim fair share of declared member dividend amount
    	//uint256 dividendAmount = ((member.tributeAmount / totalContributed) * totalDividends) - member.lastTotalDividends;
    	
    	//using SafeMathclaim fair share of declared member amount 
    	uint256 dividendAmount = totalDividends.mul(member.tributeAmount.div(totalContributed)).sub(member.lastTotalDividends);
    	
    	//member's dividend amount must be less than what is available in totalDividends
    	require (dividendAmount <= totalDividends, "Moloch - not enough funds not available");
    	//TODO
    	//check map dividendAmount to each member? or set lastTotalDividend to 0?

    	// instruct guild bank to transfer fair share to member
    	require(
        	guildBank.withdrawDividend(msg.sender, dividendAmount),
        	"Moloch::claimDividend - withdrawal of tokens from guildBank failed"
    	);
    	
    	member.lastTotalDividends = member.lastTotalDividends.add(dividendAmount);
    	totalWithdrawals = totalWithdrawals.add(dividendAmount);
	}
	
	// Extension to original Moloch Code: Summoner admin updates total dividend amount declared for members from guild bank 
	function updateTotalDividends(uint256 newDividendAmount) onlySummoner public {
	   totalDividends = totalDividends.add(newDividendAmount);
    }

	// Extension to original Moloch Code: Summoner withdraws and administers tribute tokens (but not member contributions or dividends)
	function adminWithdrawAsset(IERC20 assetToken, address receiver, uint256 amount) onlySummoner public returns (bool)  {
	    require(assetToken != contributionToken); 
        return guildBank.adminWithdrawAsset(assetToken, receiver, amount);
    }
        
	/***************
	GETTER FUNCTIONS
	***************/
    function max(uint256 x, uint256 y) internal pure returns (uint256) {
    	return x >= y ? x : y;
	}

	function getCurrentPeriod() public view returns (uint256) {
    	return now.sub(summoningTime).div(periodDuration);
	}

	function getProposalQueueLength() public view returns (uint256) {
    	return ProposalQueue.length;
	}
    
	// can only ragequit if the latest proposal you voted YES on has been processed
	function canRagequit(uint256 highestIndexYesVote) public view returns (bool) {
    	require(highestIndexYesVote < ProposalQueue.length, "Moloch::canRagequit - proposal does not exist");
    	return ProposalQueue[highestIndexYesVote].processed;
	}

	function hasVotingPeriodExpired(uint256 startingPeriod) public view returns (bool) {
    	return getCurrentPeriod() >= startingPeriod.add(votingPeriodLength);
	}

	function getProposalVote(address memberAddress, uint256 proposalIndex) public view returns (Vote) {
    	require(members[memberAddress].exists, "Moloch::getProposalVote - member doesn't exist");
    	require(proposalIndex < ProposalQueue.length, "Moloch::getProposalVote - proposal doesn't exist");
    	return ProposalQueue[proposalIndex].votesByMember[memberAddress];
	}
}

import json
import re

# The mapping table provided by the user
mapping_text = """
1 Authenticate User Mock Authenticate AuthenticateUser
2 Authenticate User Mock Change Password ManageLDAPUser
3 Get Account Transactions List GetAccountTransactionsList
4 Get Customer Accounts List GetCustAcctsList
5 Manage Customer Account Request ManageCustomerAccount
6 Manage Customer Account TTP Reply ManageCustomerAccount
7 SADAD Settlement SADADSettlementProcess
8 SADAD Settlement Request SADADSettlementProcess
9 SADAD Settlement SBA SRA Request SADADSettlementProcess
10 SADAD Settlement SBA SRA Result Reply SADADSettlementProcess
11 SADAD Settlement SRA Customer Request SADADSettlementProcess
12 SADAD Settlement SRA Customer Result Reply SADADSettlementProcess
13 ISO XML Transformer ISOXMLTransformer
14 Authenticate Tokens AuthenticateTokens
15 Authenticate User AuthenticateUser
16 Check Authorization Rules CheckAuthorizationRules
17 EB Get Beneficiary List EBGetBeneficiaryList
18 Get Beneficiary Details GetBeneficiaryDetails
19 Get Customer Dependents GetCustomerDependents
20 Manage Beneficiary ManageBeneficiary
21 BIB Account Summary Details AccountSummaryDetails
22 BIB Average Balance AverageBalance
23 BIB Total Assets And Liabilities TotalAssetsAndLiabilities
24 Get Billers List GetBillersList
25 Charge Card Payment ChargeCardPayment
26 Charge Card Update Limit ChargeCardUpdateLimit
27 Charge Card CA Transfer ChargeCardCATransfer
28 Get Card Bin Product List GetCardBinProductList
29 Get Charge Card List GetChargeCardList
30 Get Charge Card Transaction List GetChargeCardTransactionList
31 Get DR Cards List GetDRCardsList
32 Instant Card Issuance InstantCardIssuance
33 Pin Assignment PinAssignment
34 Request Card RequestCard
35 Update Card Status UpdateCardStatus
36 Update Charge Card Info UpdateChargeCardInfo
37 Get Available Commodity GetAvailableCommodity
38 Get Initial Offer GetInitialOffer
39 Manage LD ManageLD
40 Corporate Banking User Authentication ManageLDAPUser
41 Corporate Banking Change Password ManageLDAPUser
42 Corporate Banking Enable User ManageLDAPUser
43 Corporate Banking Disable User ManageLDAPUser
44 Corporate Banking Register User ManageLDAPUser
45 Corporate Banking Delete User ManageLDAPUser
46 Corporate Banking Reset Password ManageLDAPUser
47 Get LOV GetLOV
48 Get Customer Details GetCustomerDetails
49 Get Customer Loan Deposit List GetCustomerLoanDepositList
50 Get Wakala Deals GetWakalaDeals
51 Manage Wakala Deals ManageWakalaDeals
52 Get Customer Transaction List GetCustTrnsctnLst
53 Manage Customer Limits ManageCustomerLimits
54 Update Customer Info UpdateCustomerInfo
55 Get Service Fees GetServiceFees
56 EB Get Exchange Rate EBGetExchangeRate
57 Electronic Banking Fund Transfer ElectronicBankingFundTransfer
58 Get IPS Proxy List GetIPSProxyList
59 IPS Account Verification IPSAccountVerification
60 Manage IPS Proxy ManageIPSProxy
61 Manage Standing Order ManageStandingOrder
62 Remittance Calculator RemittanceCalculator
63 AML Lock Sanction Inquiry AMLLock_Snctn_Inqry
64 Check Anti Fraud Rules CheckAntiFraudRules
65 Get Digital Document Request List GetDigiDocmntRqstList
66 Get Outbound Status GetOutboundStatus
67 Manage Digital Document ManageDigitalDocument
68 Verify Manage Digital Document ManageDigitalDocument
69 Manage Nafath Authentication ManageNafathAuthentication
70 Manage Nafath Authentication Callback ManageNafathAuthentication
71 Manage Natheer Watchlist ManageNatheerWatchList
72 Manage Outbound ManageOutbound
73 Manage T24 User ManageT24User
74 Sign Documents Request SignDocuments
75 Callback Tanfeeth Execution TanfeethExecution
76 Tanfeeth Inquiry TanfeethInquiry
77 Download SADAD Billers DownloadSADADBillers
78 Get Commodity Order Status GetCommodityOrderStatus
79 Get Customer Internal Liabilities GetCustIntrnlLblts
80 Manage Digital Loan ManageDigiLoanRequest
81 Verify Mobile Number VerifyMobileNumber
82 Get MOI Service Fee GetMOIServiceFee
83 Create Investment Account CreateInvestmentAccount
84 Mubasher Cash Deposit MubasherCashDeposit
85 Mubasher Cash Withdrawal MubasherCashWithdrawal
86 Withdraw Customer Investment Account WithdrawCustomerInvsetmentAccount
87 Send Instant Notification SendInstantNotificationRequest
88 GL Transaction Notification Request GLTransactionNotification
89 Purchase Product PurchaseProduct
90 Get Standing Orders List GetStandingOrdersList
91 Get Customer Refunds GetCustomerRefunds
92 Bill Payment Debit Card Wrapper BillPayment
93 Bill Payment BillPayment
94 Bill Payment MOI Wrapper BillPayment
95 Get Biller Services List GetBillerServicesList
96 Get Yakeen Info GetYakeenInfo
97 Manage Registered Bills ManageRegisteredBills
98 Manage SSR End Of Day Process ManageSSREndOfDayProcess
99 Merge Customer Registered Bills MergeCustomerRegisteredBills
100 SADAD Cutoff Bank Serial SadadCutOff
101 SADAD Cutoff Bank Split SadadCutOff
102 SADAD Cutoff SadadCutOff
103 SADAD Reconciliation SadadCutOff
104 SADAD Refund Cutoff SadadCutOff
105 SADAD Refund Reconciliation SadadCutOff
106 Request Statement RequestStatement
107 TransFast Create Transaction TransFastCreateTransaction
108 Get Western Union Fees GetWestrenUnionFees
109 Western Union Send Money Store WestrenUnionSendMoney
110 Western Union Send Money Validation WestrenUnionSendMoney
111 Western Union Multi CSC WestrenUnionDirectAccessSystem
"""

def parse_mapping(text):
    # Regex to split lines: index original_name mapped_name
    # Since original_name can have spaces, we search for the last word as mapped_name
    lines = text.strip().split('\n')
    mapping = []
    for line in lines:
        parts = line.split()
        if len(parts) < 3:
            continue
        index = parts[0]
        mapped_name = parts[-1]
        original_name = " ".join(parts[1:-1])
        mapping.append((original_name, mapped_name))
    return mapping

def convert_json(json_path, output_path, mapping):
    with open(json_path, 'r') as f:
        data = json.load(f)
    
    new_data = {}
    
    # Track which mapped keys were used
    used_mapped_keys = set()
    
    for original_name, mapped_name in mapping:
        if mapped_name in data:
            new_data[original_name] = data[mapped_name]
            used_mapped_keys.add(mapped_name)
        else:
            print(f"Warning: Mapped key '{mapped_name}' not found in JSON for original '{original_name}'")
            new_data[original_name] = [] # Or keep it empty if not found
            
    # Also include keys from JSON that were NOT in the mapping table, if any
    for key in data:
        if key not in used_mapped_keys:
            print(f"Info: Key '{key}' in JSON was not mapped, keeping it as is or skipping? Skipping for now as user asked to convert current keys.")
            # If we skip, we might lose data. Let's keep them briefly to see.
            # new_data[key] = data[key]
            
    # Actually, the user asked to convert "the current file keys".
    # This implies the new file should ONLY have the "Original" names?
    # Or should it be a replacement?
    # User: "convert the current file keys from the mapped service Name column to the original service name column"
    # This strongly suggests the mapping table is exhaustive for what they care about.
    
    with open(output_path, 'w') as f:
        json.dump(new_data, f, indent=4)
        
    print(f"Conversion complete. New keys: {len(new_data)}")

if __name__ == "__main__":
    json_file = r'c:\Users\afakhreldin\Documents\APIC Script gitlab\apic-automation-script\service_function_ids.json'
    output_file = r'c:\Users\afakhreldin\Documents\APIC Script gitlab\apic-automation-script\service_function_ids_new.json'
    
    mapping = parse_mapping(mapping_text)
    convert_json(json_file, output_file, mapping)

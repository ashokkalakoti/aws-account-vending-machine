#!/bin/bash
function usage
{
    echo "usage: organization_new_acc.sh [-h] --account_name ACCOUNT_NAME
                                      --account_email ACCOUNT_EMAIL
                                      --cl_profile_name CLI_PROFILE_NAME
                                      [--ou_name ORGANIZATION_UNIT_NAME]
                                      [--region AWS_REGION]"
}

newAccName=""
newAccEmail=""
newProfile=""
roleName="OrganizationAccountAccessRole"
destinationOUname=""
region="ap-southeast-1"

while [ "$1" != "" ]; do
    case $1 in
        -n | --account_name )   shift
                                newAccName=$1
                                ;;
        -e | --account_email )  shift
                                newAccEmail=$1
                                ;;
        -p | --cl_profile_name ) shift
                                newProfile=$1
                                ;;
        -o | --ou_name )        shift
                                destinationOUname=$1
                                ;;
        -r | --region )        shift
                                region=$1
                                ;;
        -h | --help )           usage
                                exit
                                ;;
    esac
    shift
done

if [ "$newAccName" = "" ] || [ "$newAccEmail" = "" ] || [ "$newProfile" = "" ]
then
  usage
  exit
fi

# check if the account already exists into the orgnasation.
accstatus=$(aws --profile $masterprofile organizations list-accounts \
 --query 'Accounts[?Name==`Sandbox5 Account`]')
if [ "$accstatus" = "" ]


# Create a new Account
printf "Create New Account\n"
ReqID=$(aws --profile $masterprofile organizations create-account --email $newAccEmail --account-name "$newAccName" --role-name $roleName \
--query 'CreateAccountStatus.[Id]' \
--output text)

# Wait for Account to get ready,
printf "Waiting for New Account ..."
orgStat=$(aws --profile $masterprofile organizations describe-create-account-status --create-account-request-id $ReqID \
--query 'CreateAccountStatus.[State]' \
--output text)

while [ $orgStat != "SUCCEEDED" ]
do
  if [ $orgStat = "FAILED" ]
  then
    printf "\nAccount Failed to Create\n"
    exit 1
  fi
  printf "."
  sleep 10
  orgStat=$(aws --profile $masterprofile organizations describe-create-account-status --create-account-request-id $ReqID \
  --query 'CreateAccountStatus.[State]' \
  --output text)
done

# Get the newly created account id
accID=$(aws --profile $masterprofile organizations describe-create-account-status --create-account-request-id $ReqID \
--query 'CreateAccountStatus.[AccountId]' \
--output text)

# Use the OrganizationAccount Access Role to create the new profile for further Automation.
accARN="arn:aws:iam::$accID:role/$roleName"

printf "\nCreate New CLI Profile\n"
aws configure set region $region --profile $newProfile
aws configure set role_arn $accARN --profile $newProfile
aws configure set source_profile default --profile $newProfile  # Need to decide the Master account access/profile name, change from default to something like master-account

cfcntr=0
printf "Waiting for CF Service ..."
aws cloudformation list-stacks --profile $newProfile > /dev/null 2>&1
actOut=$?
while [[ $actOut -ne 0 && $cfcntr -le 10 ]]
do
  sleep 5
  aws cloudformation list-stacks --profile $newProfile > /dev/null 2>&1
  actOut=$?
  if [ $actOut -eq 0 ]
  then
    break
  fi
  printf "."
  cfcntr=$[$cfcntr +1]
done

if [ $cfcntr -gt 10 ]
then
  printf "\nCF Service not available\n"
  exit 1
fi

printf "\nCreate account-baseline Under New Account\n"
aws cloudformation create-stack --stack-name account-baseline --template-body file://account-baseline.json --capabilities CAPABILITY_NAMED_IAM --profile $newProfile > /dev/null 2>&1
if [ $? -ne 0 ]
then
  printf "CF account-baseline Stack Failed to Create\n"
  exit 1
fi

printf "Waiting for CF Stack to Finish ..."
cfStat=$(aws cloudformation describe-stacks --stack-name account-baseline --profile $newProfile --query 'Stacks[0].[StackStatus]' --output text)
while [ $cfStat != "CREATE_COMPLETE" ]
do
  sleep 5
  printf "."
  cfStat=$(aws cloudformation describe-stacks --stack-name account-baseline --profile $newProfile --query 'Stacks[0].[StackStatus]' --output text)
  if [ $cfStat = "CREATE_FAILED" ]
  then
    printf "\naccount-baseline Failed to Create\n"
    exit 1
  fi
done
printf "\naccount-baseline Created\n"


if [ "$destinationOUname" != "" ]
then
  printf "Moving New Account to OU\n"
  rootOU=$(aws organizations list-roots --query 'Roots[0].[Id]' --output text)
  destOU=$(aws organizations list-organizational-units-for-parent --parent-id $rootOU --query 'OrganizationalUnits[?Name==`'$destinationOUname'`].[Id]' --output text)

  aws organizations move-account --account-id $accID --source-parent-id $rootOU --destination-parent-id $destOU > /dev/null 2>&1
  if [ $? -ne 0 ]
  then
    printf "Moving Account Failed\n"
  fi
fi

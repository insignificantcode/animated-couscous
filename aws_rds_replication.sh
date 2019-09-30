#!/bin/sh
# update staging database
# script for XXXXXXXXX rds handling and replication
# nh

# Logging, to view, you must tail this log. There will be no output during CLI running of this script.
#exec 1>./rds-fun-`date +%Y%m%d-%H%M`.txt

#Testing area
#MASTER="nh-testing"
#INSTANCE="nh-testing-slave"
#CNAME=$(aws rds describe-db-instances --db-instance-identifier $INSTANCE --output text | grep -i endpoint | awk {'print $2'})
#FQDN="rds-test.XXXXXXXX"
#HOSTEDZONE="Z1TUUQXPZQXE4C"
#SG="sg-XXXXXX"
#LASTCREATE="`aws rds describe-db-instances --db-instance-identifier nh-testing-slave | grep "InstanceCreateTime" | awk '{print substr($2,2,17)}' | tr -d "-" | tr -d "T" | tr -d ":"`"

MASTER="catalog-ticket-8216"
INSTANCE="slave-catalog-ticket-8216"
CNAME=$(aws rds describe-db-instances --db-instance-identifier $INSTANCE --output text | grep -i endpoint | awk {'print $2'})
FQDN="test_rds_instance-XXXXXXXX-catalog-uat.XXXXXXXX.com"
HOSTEDZONE="Z1ZW8MSVRL2RC0"
SG1="sg-XXXXX"
SG2="sg-XXXXXXXX"
LASTCREATE="`aws rds describe-db-instances --db-instance-identifier $INSTANCE | grep "InstanceCreateTime" | awk '{print substr($2,2,17)}' | tr -d "-" | tr -d "T" | tr -d ":"`"

# Check status of current RDS instance (possibly pull some facts from the output) -- FOR TESTING
#aws rds describe-db-instances --db-instance-identifier $INSTANCE --output text

# Here we will delete the replicated RDS instance, probably best to save a snapshot before actually tearing it down, but we won't :).
echo "**** We will now start the deletion of $INSTANCE. Our last creation date/time was $LASTCREATE ****"
echo " "
aws rds delete-db-instance --db-instance-identifier $INSTANCE --skip-final-snapshot --output text

# Here we look for description status of "DB instance deleted" then continue with the replication when confirmed deleted.
while [[ ${STATUS} != "DB instance deleted" ]]
    do
        STATUS=`aws rds describe-events --output text --duration 5 | grep deleted | awk -F $'\t' '{print $3}'`
        if [[ ${STATUS} = "DB instance deleted" ]] ;
        then
            echo "**** $STATUS! We will continue with replication. First check will be in 30 seconds. ****"
        elif [[ ${STATUS} !=  "DB instance deleted" ]] ;
        then
            sleep 30
            echo "**** DB instance deletion has not yet completed. Sleeping for 60 seconds, then trying again. ****"
            sleep 60
        else
            echo "Failed"
        fi
    done

# Create the slave off of the master, again doing some checks to see when it has completed. Will take at least 5-10 minutes.
aws rds create-db-instance-read-replica --db-instance-identifier $INSTANCE --source-db-instance-identifier $MASTER --output text

while [[ ${REPLICA} != "Replication for the Read Replica resumed" ]]
    do
        REPLICA=`aws rds describe-events --duration 10 --output text | awk -F $'\t' '{print $3}' | grep resumed`
        if [[ ${REPLICA} = "Replication for the Read Replica resumed" ]] ;
        then
            echo "**** $REPLICA has completed! To insure replication is in a successful state, we will sleep for 60 seconds before we proceed with the promotion of this instance. ****"
            echo " "
            sleep 60
        elif [[ ${REPLICA} !=  "**** Replication for the Read Replica resumed ****" ]] ;
        then
            echo "Replication has not been completed, and we cannot continue with promotion. Sleeping for 60 seconds, then trying again."
            sleep 60
        else
            echo "Failed"
        fi
    done

# Promote this instance and check the status of promotion.
aws rds promote-read-replica --db-instance-identifier $INSTANCE --output text

while [[ ${PROMOTE} != "Finished DB Instance backup" ]]
    do
        PROMOTE=`aws rds describe-events --duration 5 --output text | awk -F $'\t' '{print $3}' | grep Finished`
        if [[ ${PROMOTE} = "Finished DB Instance backup" ]] ;
        then
            echo "**** $PROMOTE! We can now proceed with updating DNS to our new endpoint. ****"
            echo " "
            sleep 5
        elif [[ ${PROMOTE} !=  "Finished DB Instance backup" ]] ;
        then
            echo "**** RDS backup has not been completed, and we cannot continue with DNS update. Sleeping for 60 seconds, then trying again. ****"
            sleep 60
        else
            echo "Failed"
        fi
    done
    
# Configure new replicated master's security group make public and apply immediately.
# We will use SG sg-XXXXXX and sg-XXXXXXX for XXXXXXXX
aws rds modify-db-instance --db-instance-identifier $INSTANCE --publicly-accessible --vpc-security-group-ids $SG1, $SG2 --apply-immediately --output text

# Update DNS to point the CNAME to the new instance endpoint, use CLI input instead of batch file.
aws route53 change-resource-record-sets --hosted-zone-id $HOSTEDZONE --cli-input-json '{
    "HostedZoneId": "'$HOSTEDZONE'",
    "ChangeBatch": {
    "Comment": "This will update the CNAME for our RDS instance.",
    "Changes": [
         {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "'$FQDN'",
                "Type": "CNAME",
                "TTL": 600,
             "ResourceRecords": [
               {
                 "Value": "'$CNAME'"
               }
             ]
           }
        }
     ]
  }
}'


echo "**** DNS update has been completed, please wait 15 to 20 minutes for propagation. ****"
echo " "

# Let's check the last creation time to see if it is recent enough. If not, we will send out an error in an email.

        NEWCREATE="`aws rds describe-db-instances --db-instance-identifier $INSTANCE | grep "InstanceCreateTime" | awk '{print substr($2,2,17)}' | tr -d "-" | tr -d "T" | tr -d ":"`"
        if [ "$NEWCREATE" -gt "$LASTCREATE" ] ;
        then
            echo "**** Our RDS instance is newer $NEWCREATE than the Last Creation time $LASTCREATE, we can assume it has been created successfully ****"

        elif [ "$NEWCREATE" -eq "$LASTCREATE" ] || [ "$NEWCREATE" -lt "$LASTCREATE" ] ;
        then
           echo "Creation time is the same, instance creation has failed"
        else
            echo "**** The RDS instance has not been replicated. We will need to check the failure. ****"
            echo "we will mail here, but this is a place holder for now"
        fi

echo "**** The instance $INSTANCE, deletion, replication, promotion and DNS updates have been completed. Please come again! ****"

# add notification down here in the future.

#!/bin/bash
# ------------------------------------------------------------------- #
# Copyright (c) 2019 LINKIT, The Netherlands. All Rights Reserved.
# Author(s): Anthony Potappel
# 
# This software may be modified and distributed under the terms of
# the MIT license. See the LICENSE file for details.
# --------------------------------------------------------------------#
set -x -e -o pipefail

# base script dependencies -- if GITURL is used, git is also required
DEPENDENCIES="aws jq sed awk date basename"
PROGNAME="cfn_deploy.sh"

function usage(){
    cat << USAGE
  Notes
    ${PROGNAME} deploy a CloudFormation stack on AWS.
  Usage:
    command:    ${PROGNAME} <ACTION> [OPTIONS]

  ACTIONS
    --deploy        Deploy or Update Application Stack
    --delete        Delete Application Stack
    --delete_all    Delete Configuration- and Application Stack
    --status        Retrieve Status of Application Stack
    --account       Check Configured Account
    --help          Show this Help

  OPTIONS
    -n      set STACKNAME
    -u      set GITURL
    -p      set AWS_PROFILE
    -r      set AWS_DEFAULT_REGION
    -f      set ENVIRONMENT_FILE

  ENVIRONMENT_FILE
    Optional file. All variables are retrieved from environment and
    can be overridden by an ENVIRONMENT_FILE. Defaults are generated
    for missing variables, where possible.

    # Name of stack should be unique per AWS account. Defaults to
    # name of directory where ${PROGNAME} is run from.
    STACKNAME=cfn-deploy-demo

    # (optional) source contents from a GIT repository
    GITURL=https://github.com/[GROUP]/REPO].git?branch=master&commit=

    # name of template_file to be run in mainstack
    # default path lookup: current scriptpath; ./\${TEMPLATE_FILE}
    # if GITURL is defined: ./build/current/\${TEMPLATE_FILE}
    TEMPLATE_FILE=app/main.yaml

    # AWS_* PARAMETERS are all loaded as-is
    # check: https://docs.aws.amazon.com/\
                cli/latest/userguide/cli-chap-configure.html

    # use profiles, configuration in ~/.aws/[config,credentials]
    AWS_PROFILE=DevAccount  --or-- AWS_DEFAULT_PROFILE=DevAccount

    # set region -- defaults to eu-west-1
    AWS_DEFAULT_REGION=eu-west-1

    # credentials through environment
    # values are discarded if AWS_PROFILE is defined
    AWS_ACCESS_KEY_ID=secretaccount
    AWS_SECRET_ACCESS_KEY=mysecret
    AWS_SESSION_TOKEN=sts-generated-token

USAGE
    return 0
}

function error(){
    # Default error function with hard exit
    [ ! -z "$1" ] && echo "ERROR:$1"
    exit 1
}

function git_destination(){
    # Return clean repository name -- filter out .git and any parameters
    base=$(basename "${1}")
    var=$(
        echo "${base}" \
        |sed 's/\.git$//g;s/[^a-zA-Z0-9_-]//g'
    )
    if [ ! -z "${var}" ];then
        echo "${var}"
        return 0
    elif [ "${base}" = "." ];then
        # GIT Repo is current directory
        echo "${STACKNAME}"
        return 0
    fi
    return 1
}

function git_parameter(){
    # Return parameter from GIT URL -- return _default if not found
    filter="${1}"
    default="${2}"
    url="${3}"
    parameter_value=""

    # filter parameter string from url
    parameter_str=$(
        basename "${url}" \
        |sed 's/?\|$/__/g;
              s/\(__[-a-zA-Z0-9=&]*__\)/__\1/g;' \
        |sed -n 's;.*\(__.*__\);\1;p'
    )

    # filter out specific parameter
    [ ! -z "${parameter_str}" ] \
        && parameter_value=$(
            echo "${parameter_str}" \
            |sed -n 's;.*\('${filter}'=[A-Za-z0-9-]*\).*;\1;p' \
            |sed 's/^'${filter}'=//g'
        )

    # if no match, return default
    [ -z "${parameter_value}" ] && parameter_value="${default}"
    echo "${parameter_value}"
    return 0
}

function git_auto_commit(){
    # commit all changes automatically
    [ ! -d ".git" ] && return 1
    git add . \
    && (
        git diff-index --quiet HEAD \
        || git commit -am "__auto_update__:$(date +%s)"
    )
    return $?
}

function update_from_git(){
    # Fetch repository and checkout to specified branch tag/commit
    # for this function, git is a requirement
    command -v git || error "git not installed"

    branch=$(git_parameter "branch" "master" "${GITURL}")
    commit=$(git_parameter "commit" "" "${GITURL}")

    repository_url=$(echo "${GITURL}" |sed 's/?.*//g')
    repository_name=$(git_destination "${repository_url}") || return 1
    destination="./build/${repository_name}"

    # fetch if exist or clone if new
    (
        [ -e "${destination}/.git" ] \
        &&  (
                cd "${destination}" && git fetch
            ) \
        || git clone -b "${branch}" "${repository_url}" "${destination}" \
        || return 1
    )

    # move to correct position in GIT repository
    if [ ! -z "${commit}" ];then
        # point to given branch commit/tag 
        (
            cd "${destination}" \
            && git checkout -B ${branch} ${commit} \
            || return 1
        )
    else
        # point to latest in branch
        (
            cd "${destination}" \
            && git checkout -B ${branch} \
            && git pull \
            || return 1
        )
    fi

    # succesful install - update symlink
    [ -e "./build/current" ] \
    &&  (
            rm -f "./build/current" || return 1
        )
    ln -sf "${repository_name}" "./build/current"
    return $?
}

function get_bucket(){
    # Return Name of S3 bucket deployed by RootStack
    stackname="$1"
    response=$(
        aws cloudformation describe-stacks ${PROFILE_STR} \
        --stack-name "${stackname}" \
        --query 'Stacks[0].Outputs[?OutputKey==`S3BucketName`].OutputValue' \
        --output text 2>/dev/null
    )
    [ ! -z "${response}" ] && echo "${response}"
    return $?
}

function get_bucket_url(){
    # Return URL of S3 bucket deployed by RootStack
    # Bucket URL is used to reference the location of (nested) stacks
    stackname="$1"
    response=$(
        aws cloudformation describe-stacks ${PROFILE_STR} \
        --stack-name "${stackname}" \
        --query 'Stacks[0].Outputs[?OutputKey==`S3BucketSecureURL`].OutputValue' \
        --output text 2>/dev/null
    )
    [ ! -z "${response}" ] && echo "${response}"
    return $?
}

function get_role_arn(){
    # Return ARN of Role deployed by RootStack
    stackname="$1"
    response=$(
        aws iam list-roles ${PROFILE_STR} \
        |jq -r '.Roles
             | .[]
             | select(.RoleName=="'${stackname}'-ServiceRoleForCloudFormation")
             | .Arn'
    )
    [ ! -z "${response}" ] && echo "${response}"
    return $?
}

function deploy_configuration(){
    # Deploy Configuration-- typically contains S3 Bucket and IAM Role
    stackname="$1"
    aws cloudformation deploy ${PROFILE_STR} \
        --no-fail-on-empty-changeset \
        --template-file ./build/configuration_stack.yaml \
        --capabilities CAPABILITY_NAMED_IAM \
        --stack-name "${stackname}" \
        --parameter-overrides StackName="${stackname}"
    return $?
}

function process_stackname(){
    # (Re-)Format to CloudFormation compatible stack names
    # [a-zA-Z-], remove leading/ trailing dash, uppercase first char (just cosmetics)
    STACKNAME=$(
        echo ${1} \
        |sed 's/[^a-zA-Z0-9-]/-/g;s/-\+/-/g;s/^-\|-$//g' \
        |awk '{for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1'
    )

    if [ "${#STACKNAME}" -lt 1 ];then
        # this should never happen, but if name is empty default to Unknown
        STACKNAME="Unknown"
    elif [ "${#STACKNAME}" -gt 64 ];then
        # shorten name, and remove possible new leading/ trailing dashes
        STACKNAME=$(echo ${STACKNAME:0:64} |sed s'/^-\|-$//g')
    fi
    [ ! -z "${STACKNAME}" ] && echo ${STACKNAME}
    return $?
}

function account(){
    # --account Verify account used to deploy or delete
    # exit on error
    trap error ERR

    # disable verbosity to get clean output
    set +x
    outputs=$(aws sts get-caller-identity ${PROFILE_STR})
    echo "Account used:"
    echo "${outputs}" | jq
    exitcode=$?

    # re-enable verbosity
    set -x
    return ${exitcode}
}

function stack_delete_waiter(){
    # Wait ~15 minutes before returning a fail
    max_rounds=300
    seconds_per_round=3
    stack_name="${1}"

    set +x
    i=0
    while [ ${i} -lt ${max_rounds} ];do
        outputs=$(aws cloudformation describe-stacks ${PROFILE_STR} \
            --stack-name "${stack_name}" 2>/dev/null || true)
        [ -z "${outputs}" ] && break

        stack_status=$(echo "${outputs}" | jq -r .Stacks[0].StackStatus)
        echo "WAITER (${i}/${max_rounds}):${stack_name}:${stack_status}"

        i=$[${i}+1]
        sleep ${seconds_per_round}
    done
    set -x

    # Delete success if outputs is empty
    [ -z "${outputs}" ] && return 0
    return 1
}

function delete_application(){
    # --delete  Delete stack
    # exit on error
    trap error ERR

    # output account used in this deployment
    account

    configuration_stack="${STACKNAME}-Configuration"
    application_stack="${STACKNAME}-Main"

    # Retrieve key items created by the configuration stack
    role_arn=$(get_role_arn "${configuration_stack}")

    # delete main_stack
    aws cloudformation delete-stack ${PROFILE_STR} \
        --role-arn "${role_arn}" \
        --stack-name "${application_stack}"

    stack_delete_waiter "${application_stack}" \
        || error "Failed to delete Application Stack"
    return 0
}

function delete_configuration(){
    # --delete_configuration    Delete configuration stack 
    # this will fail if stacks depend on it

    # exit on error
    trap error ERR

    # output account used in this deployment
    account

    configuration_stack="${STACKNAME}-Configuration"
    application_stack="${STACKNAME}-Main"

    # Check if configuration_stack exists, if not -- nothing to delete
    outputs=$(aws cloudformation describe-stacks ${PROFILE_STR} \
        --stack-name "${configuration_stack}" 2>/dev/null || true)
    [ -z "${outputs}" ] && return 0

    # Only delete Configuration Stack if no Application Stack depends on it
    stack_delete_waiter "${application_stack}" \
        || error "Cant delete because Application Stack exists"

    # Retrieve key items created by the configuration stack
    bucket=$(get_bucket "${configuration_stack}")

    # delete configuration stack
    aws cloudformation delete-stack ${PROFILE_STR} \
        --stack-name "${configuration_stack}"

    stack_delete_waiter "${configuration_stack}" \
        || error "Failed to delete Configuration Stack"
    return 0
}

function status(){
    # --status  Retrieve status of stack
    # exit on error
    trap error ERR

    # output account used in this deployment
    account

    configuration_stack="${STACKNAME}-Configuration"
    main_stack="${STACKNAME}-Main"

    outputs=$(aws sts get-caller-identity ${PROFILE_STR})

    set +x
    # configuration_stack --allowed to fail if not exist
    outputs=$(aws cloudformation describe-stacks ${PROFILE_STR} \
        --stack-name "${configuration_stack}" 2>/dev/null || true)
    if [ ! -z "${outputs}" ];then
        echo "ConfigurationStack:"
        echo "${outputs}" | jq
    else
        echo "No ConfigurationStack found"
    fi

    # main_stack -- allowed to fail if not exist
    outputs=$(aws cloudformation describe-stacks ${PROFILE_STR} \
        --stack-name "${main_stack}" 2>/dev/null || true)
    if [ ! -z "${outputs}" ];then
        echo "MainStack:"
        echo "${outputs}" | jq
    else
        echo "No MainStack found"
    fi

    # re-enable verbosity
    set -x
    return 0
}

function deploy(){
    # --deploy  Deploy or Update stack
    # exit on error
    trap error ERR


    # output account used in this deployment
    account

    # Ensure current path is correct -- relative paths are used in this function
    cd "${SCRIPTPATH}" || return 1

    configuration_stack="${STACKNAME}-Configuration"
    main_stack="${STACKNAME}-Main"

    # deploy configuration stack (includes S3 Bucket, CloudFormation Role)
    deploy_configuration "${configuration_stack}"

    # Retrieve key items created by the configuration stack
    bucket=$(get_bucket "${configuration_stack}")
    bucket_url=$(get_bucket_url "${configuration_stack}")
    role_arn=$(get_role_arn "${configuration_stack}")

    srcdir=""
    appdir="app"
    appmain="main.yaml"

    if [ -d "./build/current/${appdir}" ];then
        srcdir="./build/current/${appdir}"
    elif [ -d "./${appdir}" ];then
        srcdir="./${appdir}"
    fi

    #export TEMPLATE_FILE="build/current/${TEMPLATE_FILE}"
    # Copy or update files in S3 bucket created by the configuration stack
    #./build/current \
    aws s3 sync ${PROFILE_STR} \
        "${srcdir}" \
        s3://"${bucket}/${appdir}"

    # deploy main_stack
    aws cloudformation deploy ${PROFILE_STR} \
        --template-file "${srcdir}/${appmain}" \
        --role-arn "${role_arn}" \
        --stack-name "${main_stack}" \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
        --parameter-overrides \
            S3BucketName="${bucket}" \
            S3BucketSecureURL="${bucket_url}/app" \
            IAMServiceRole="${role_arn}" \
            LastChange=`date +%Y%m%d%H%M%S`

    # Get stackoutputs of MainStack -- allow jq to fail if none are found
    outputs=$(\
        aws cloudformation describe-stacks ${PROFILE_STR} \
            --stack-name "${main_stack}" \
        |(
            jq '.Stacks[0].Outputs[] | {"\(.OutputKey)": .OutputValue}' 2>/dev/null \
            || echo "{}"
         ) \
        |jq -s add
    )

    # disable verbosity to get clean output
    set +x
    echo "Finished succesfully! Outputs of MainStack:"
    echo "${outputs}" | jq
    set -x
    return 0
}

function configure_build(){
    # Ensure current path is correct -- relative paths are used in this function
    cd "${SCRIPTPATH}" || return 1

    # ensure build dir exist
    if [ ! -d "./build" ];then
        (
            mkdir -p "./build" \
            || return 1
        )
    fi
    # ensure everything under ./build is ignored by git
    cat << IGNORE_FILE_BUILD >./build/.gitignore
# ignore everything under build
# build/* should only contain generated data
# this file is auto-generated by ${PROGNAME}
*
IGNORE_FILE_BUILD

    # add configuration stack template to ./build
    cat << CONFIGURATION_STACK >./build/configuration_stack.yaml
AWSTemplateFormatVersion: 2010-09-09
Description: ConfigurationStack
Parameters:
  StackName:
    Type: String
Resources:
  Bucket:
    Type: AWS::S3::Bucket
    Properties:
      VersioningConfiguration:
        Status: Enabled
      LifecycleConfiguration:
        Rules:
        - ExpirationInDays: 30
          Status: Disabled
        - NoncurrentVersionExpirationInDays: 7
          Status: Enabled
      BucketEncryption:
        ServerSideEncryptionConfiguration:
        - ServerSideEncryptionByDefault:
            SSEAlgorithm: AES256
  ServiceRoleForCloudFormation:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub \${StackName}-ServiceRoleForCloudFormation
      AssumeRolePolicyDocument:
        Statement:
        - Effect: Allow
          Principal:
            Service:
            - cloudformation.amazonaws.com
          Action:
          - sts:AssumeRole
      Policies:
      - PolicyName: AdministratorAccess
        PolicyDocument:
          Version: 2012-10-17
          Statement:
          - Effect: Allow
            Action: "*"
            Resource: "*"
  BucketEmptyRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Statement:
        - Effect: Allow
          Principal:
            Service:
            - lambda.amazonaws.com
          Action:
          - sts:AssumeRole
      Policies:
      - PolicyName: WriteCloudwatchLogs
        PolicyDocument:
          Version: 2012-10-17
          Statement:
          - Effect: Allow
            Action:
            - logs:CreateLogGroup
            - logs:CreateLogStream
            - logs:PutLogEvents
            Resource:
            - arn:aws:logs:*:*:*
          - Effect: Allow
            Action:
            - s3:List*
            - s3:DeleteObject
            - s3:DeleteObjectVersion
            Resource:
            - !Sub \${Bucket.Arn}
            - !Sub \${Bucket.Arn}/*
  BucketEmptyLambda:
    Type: AWS::Lambda::Function
    Properties:
      Runtime: python3.7
      Handler: index.handler
      Role: !GetAtt BucketEmptyRole.Arn
      Code:
        ZipFile: |
          import boto3
          import cfnresponse

          s3 = boto3.resource('s3')

          def empty_s3(payload):
              bucket = s3.Bucket(payload['BucketName'])
              bucket.object_versions.all().delete()
              return {}

          def handler(event, context):
              try:
                  if event['RequestType'] in ['Create', 'Update']:
                      # do nothing
                      cfnresponse.send(event, context, cfnresponse.SUCCESS,
                                       {}, event['LogicalResourceId'])
                  elif event['RequestType'] in ['Delete']:
                      response = empty_s3(event['ResourceProperties'])
                      cfnresponse.send(event, context, cfnresponse.SUCCESS, response)

              except Exception as e:
                  cfnresponse.send(event, context, "FAILED", {"Message": str(e)})
  CustomCrlBucketEmpty:
    Type: Custom::CrlBucketEmpty
    Properties:
      ServiceToken: !GetAtt BucketEmptyLambda.Arn
      BucketName: !Ref Bucket
Outputs:
  S3BucketName:
    Value: !Ref Bucket
  S3BucketSecureURL:
    Value: !Sub https://\${Bucket.RegionalDomainName}
  IAMServiceRole:
    Value: !GetAtt ServiceRoleForCloudFormation.Arn
CONFIGURATION_STACK
    return $?
}

function parse_opts(){
    # retrieve and parse extra arguments
    # store n,u,p and r as temporary vars to allow override after
    # CLI arguments take precedence over environment_file
    while getopts "n:u:p:r:f:" opt;do
        case "$opt" in
            n) export _STACKNAME="$OPTARG";;
            u) export _GITURL="$OPTARG";;
            p) export _AWS_PROFILE="$OPTARG";;
            r) export _AWS_DEFAULT_REGION="$OPTARG";;
            f) export ENVIRONMENT_FILE="$OPTARG";;
        esac
    done
    return 0
}

function set_defaults(){
    # Ensure essential variables are set
    # Path from where this script runs -- ensure its not empty
    SCRIPTPATH=$(
        cd $(dirname "${BASH_SOURCE[0]}" || error "Cant retrieve directory") \
        && pwd \
        || return 1
    )
    [ ! -z "${SCRIPTPATH}" ] && export SCRIPTPATH="${SCRIPTPATH}" || return 1

    configure_build || return 1

    # Optional. If environment file is passed, load variables from file
    if [ ! -z "${ENVIRONMENT_FILE}" ];then
        if [ -s "${ENVIRONMENT_FILE}" ];then
            echo "Loading: ${ENVIRONMENT_FILE}"
            # - source relevant variables -- AWS_* and vars that can be overriden
            # - stick with sed to limit script dependencies
            export $(
                sed -n \
                    '/^AWS_[A-Z_]*=.*$/p;
                    /^STACKNAME=.*$/p;
                    /^GITURL=.*$/p;
                    /^TEMPLATE_FILE=.*$/p' \
                "${ENVIRONMENT_FILE}"
            )
        else
            echo "File \"${ENVIRONMENT_FILE}\" is empty or does not exist"
        fi
    fi

    # copy from CLI if set earlier -- this has precedence over ENVIRONMENT_FILE
    [ ! -z "${_STACKNAME}" ] && export STACKNAME="${_STACKNAME}"
    [ ! -z "${_GITURL}" ] && export GITURL="${_GITURL}"
    [ ! -z "${_AWS_PROFILE}" ] && export AWS_PROFILE="${_AWS_PROFILE}"
    [ ! -z "${_AWS_DEFAULT_REGION}" ] && export AWS_DEFAULT_REGION="${_AWS_DEFAULT_REGION}"

    # TEMPLATE_FILE: main template called to run (main) rootstack
    # default: path lookup from current scriptpath (./ -- where this script runs)
    # when GITURL is definied: path is ./build/current/${TEMPLATE_FILE}
    #[ -z "${TEMPLATE_FILE}" ] && export TEMPLATE_FILE="app/main.yaml"

    # STACKNAME set in environment file, defaults to basename of scriptpath
    # additional processing to ensure compatibility with AWS Stack naming scheme
    if [ -z "${STACKNAME}" ];then
        export STACKNAME=$(process_stackname "$(basename "${SCRIPTPATH}")")
    else
        export STACKNAME=$(process_stackname "${STACKNAME}")
    fi

    # Copy AWS_DEFAULT_PROFILE TO AWS_PROFILE, if former exists and latter is unset
    if [ -z "${AWS_PROFILE}" ] && [ ! -z ${AWS_DEFAULT_PROFILE} ];then
        export AWS_PROFILE=${AWS_DEFAULT_PROFILE}
    fi

    # PROFILE_STR is added if AWS_PROFILE is set
    # while AWS CLI default behavior is to pickup from environment,
    # adding to every command makes profile usage explicit in logging
    if [ ! -z "${AWS_PROFILE}" ];then
        # TODO: check for space
        export PROFILE_STR="--profile ${AWS_PROFILE}"
    else
        unset PROFILE_STR
    fi

    # ensure a default region is set
    [ -z "${AWS_DEFAULT_REGION}" ] && export AWS_DEFAULT_REGION=eu-west-1
    return 0
}

function check_dependencies(){
    # Verify prerequisite tools
    for tool in ${DEPENDENCIES};do
        command -v ${tool} || error "${tool} not installed"
    done
}

# verify prerequisite tools first
check_dependencies

# parse CLI arguments
action="${1}"
if [ ! -z "${action}" ];then
    # ensure essential variables are set in environment
    shift
    parse_opts $@
    set_defaults
fi

case "${action}" in
    --deploy)   # if GITURL is used, fetch and checkout repository, update TEMPLATE_FILE
                [ ! -z "${GITURL}" ] && update_from_git || error "Repository pull failed"
                deploy;;
    --commit_deploy)
                [ -z "${GITURL}" ] && export GITURL="."
                git_auto_commit \
                && update_from_git \
                && deploy;;
    --commit)   git_auto_commit;;
    --checkout) update_from_git;;
    --delete)   delete_application;;
    --delete_all)
                delete_application \
                && delete_configuration;;
    --status)   status;;
    --account)  account;;
    --help)     usage;;
    *)  usage;;
esac
exit $?

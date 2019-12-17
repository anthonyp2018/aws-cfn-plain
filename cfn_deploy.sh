#!/bin/bash
# ------------------------------------------------------------------- #
# Copyright (c) 2019 LINKIT, The Netherlands. All Rights Reserved.
# Author(s): Anthony Potappel
# 
# This software may be modified and distributed under the terms of
# the MIT license. See the LICENSE file for details.
# --------------------------------------------------------------------#
set -x -e -o pipefail

# base script dependencies
DEPENDENCIES="aws git jq find sed awk date ln basename dirname"
PROGNAME="cfn_deploy.sh"

function usage(){
    cat << USAGE
  Notes
    ${PROGNAME} deploy a CloudFormation stack on AWS.
  Usage:
    command:    ${PROGNAME} <ACTION> [<REPOSITORY>] [OPTIONS]

  ACTIONS
    --deploy    <REPOSITORY>    Deploy or Update Application Stack
    --delete    <REPOSITORY>    Delete Application Stack
    --checkout  <REPOSITORY>    Checkout GIT repository, or init new
                                if argument passed is "."
    --status    <REPOSITORY>    Retrieve Status of Application Stack

    --deploy_configuration      Deploy Configuration Stack
    --delete_configuration      Delete Configuration Stack
    --validate_account          Validate Configured Account
    --help                      Show this Help

  OPTIONS
    -p      set AWS_PROFILE
    -r      set AWS_DEFAULT_REGION
    -w      auto commit before --deploy or --checkout
    -f  <ENVIRONMENT_FILE>
            set OPTIONS via ENVIRONMENT_FILE
    -c      override CONFIGURATION_STACKNAME
    -a      override APPLICATION_STACKNAME

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
        echo "$(basename "${SCRIPTPATH}")"
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
    # for OSX compatibility: dont use: \|
    parameter_str=$(
        basename "${url}" \
        |sed 's/?/__/g;
              s/$/__/g;
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

function git_namestring(){
    # Return a string containing Repository Name, Branch and Commit
    branch=$(git_parameter "branch" "master" "${REPOSITORY}")
    commit=$(git_parameter "commit" "latest" "${REPOSITORY}")

    repository_url=$(echo "${REPOSITORY}" |sed 's/?.*//g')
    repository_name=$(git_destination "${repository_url}") || return 1

    echo "${repository_name}-${branch}-${commit}"
    return $?
}

function git_auto_commit(){
    # commit all changes automatically
    [ ! -d ".git" ] && return 1

    git_username=$(git config user.name)
    git_useremail=$(git config user.email)

    [ -z "${git_username}" ] && git config user.name `whoami`
    [ -z "${git_useremail}" ] && git config user.email `whoami`@localhost

    git add . \
        && (
            git diff-index --quiet HEAD \
            || git commit -am "__auto_update__:$(date +%s)"
        )
    return $?
}
    
function validate_auto_commit(){
    # commit existing work if option (-w) is set

    # return with ok status if auto_commit is not set
    [ -z "${AUTO_COMMIT}" ] \
        ||  [ "${AUTO_COMMIT}" != "true" ]  \
        && return 0
    git_auto_commit
    return $?
}

function update_from_git(){
    # Fetch repository and checkout to specified branch tag/commit
    branch=$(git_parameter "branch" "master" "${REPOSITORY}")
    commit=$(git_parameter "commit" "" "${REPOSITORY}")

    repository_url=$(echo "${REPOSITORY}" |sed 's/?.*//g')
    repository_name=$(git_destination "${repository_url}") || return 1
    destination="./build/${repository_name}"

    # ./build must exist -- also includes creation of .gitignore
    create_buildpath || return 1

    # fetch if exist or clone if new
    [ -e "${destination}/.git" ] \
        &&  (
                cd "${destination}" && git fetch
            ) \
        || git clone -b "${branch}" "${repository_url}" "${destination}" \
        || return 1

    # move to correct position in GIT repository
    if [ ! -z "${commit}" ];then
        # point to given branch commit/tag 
        cd "${destination}" \
            && git checkout -B ${branch} ${commit} \
            || return 1
    else
        # point to latest in branch
        cd "${destination}" \
            && git checkout -B ${branch} \
            && git pull \
            || return 1
    fi

    # succesful install - update symlink
    [ -e "./build/current" ] \
        &&  (
            rm -f "./build/current" || return 1
        )
    # Validate path
    cd "${SCRIPTPATH}" && ln -nsf "${repository_name}" "./build/current"
    return $?
}

function get_bucket(){
    # Return Name of S3 bucket deployed by RootStack
    stackname="${1}"
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
    stackname="${1}"
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
    stackname="${1}"
    response=$(
        aws cloudformation describe-stacks ${PROFILE_STR} \
            --stack-name "${stackname}" \
            --query 'Stacks[0].Outputs[?OutputKey==`IAMServiceRole`].OutputValue' \
            --output text 2>/dev/null
    )
    [ ! -z "${response}" ] && echo "${response}"
    return $?
}

function process_stackname(){
    # (Re-)Format to CloudFormation compatible stack names
    # [a-zA-Z-], remove leading/ trailing dash, uppercase first char (just cosmetics)
    stackname=$(
        echo ${1} \
        |sed 's/[^a-zA-Z0-9-]/-/g;s/-\+/-/g;s/^-\|-$//g' \
        |awk '{for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1'
    )

    if [ "${#stackname}" -lt 1 ];then
        # this should never happen, but if name is empty default to Unknown
        stackname="Unknown"
    elif [ "${#stackname}" -gt 64 ];then
        # shorten name, and remove possible new leading/ trailing dashes
        stackname=$(echo ${stackname:0:64} |sed s'/^-\|-$//g')
    fi
    [ ! -z "${stackname}" ] && echo ${stackname}
    return $?
}

function validate_account(){
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
    validate_account || return 1

    configuration_stack="${CONFIGURATION_STACKNAME}-Configuration"
    application_stack="${APPLICATION_STACKNAME}-Application"

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
    validate_account || return 1

    configuration_stack="${CONFIGURATION_STACKNAME}-Configuration"
    application_stack="${APPLICATION_STACKNAME}-Main"

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
    validate_account || return 1

    configuration_stack="${CONFIGURATION_STACKNAME}-Configuration"
    main_stack="${APPLICATION_STACKNAME}-Main"

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

function deploy_configuration(){
    # --deploy_configuration    Deploy Configuration Stack
    # exit on error
    trap error ERR

    # output account used in this deployment
    validate_account || return 1

    template_name="configuration_stack.yaml"
    create_configuration_template "${template_name}" || return 1

    # validate path
    cd "${SCRIPTPATH}" || return 1

    # deploy configuration stack -- S3 Bucket, IAM Role
    stackname="${CONFIGURATION_STACKNAME}-Configuration"
    aws cloudformation deploy ${PROFILE_STR} \
        --no-fail-on-empty-changeset \
        --template-file "./build/${template_name}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --stack-name "${stackname}" \
        --parameter-overrides StackName="${stackname}"
    return $?
}

function sambuild(){
    cd "${BUILDPATH}" || return 1

    # ${DIRECTORY}/template.yaml to be a sam template
    templates=$(find ./ -mindepth 2 -maxdepth 3 -name template.yaml)
    [ -z "${templates}" ] && return 0

    # sam is required if templates are found
    command -v sam || error "sam cli not installed"

    # sam default template location -- dont change this
    sam_template=".aws-sam/build/template.yaml"
    bucket="${1}"

    for template in ${templates};do
        # build if newer file(s) exists
        template_dir="${BUILDPATH}/$(dirname "${template}")"

        cd "${template_dir}" || return 1
        newfiles=$(
            [ -s "${sam_template}" ] \
            && find . -path .aws-sam -prune -o -type f -newer packaged.yaml \
            || echo y
        )
        [ -z "${newfiles}" ] && continue
        if [ -f __init__.py ];then
            command -v pipenv || error "pipenv required for Python Packages"
            pipenv lock -r >requirements.txt
        fi
        sam build -t template.yaml ${PROFILE_STR} || return 1
        sam package \
            --template-file "${sam_template}" \
            --s3-bucket "${bucket}" \
            --s3-prefix "sam" \
            --output-template-file "packaged.yaml" \
            ${PROFILE_STR}
    done

    # return list of templates to signal sam templates are built
    echo "${templates}"
    return 0
}

function deploy(){
    # Retrieve key items created by the configuration stack
    configuration_stack="${CONFIGURATION_STACKNAME}-Configuration"
    application_stack="${APPLICATION_STACKNAME}-Application"

    # get configuration -- or deploy configuration and retry
    bucket=$(get_bucket "${configuration_stack}") \
        && bucket_url=$(get_bucket_url "${configuration_stack}") \
        && role_arn=$(get_role_arn "${configuration_stack}") \
        || deploy_configuration \
            && bucket=$(get_bucket "${configuration_stack}") \
            && bucket_url=$(get_bucket_url "${configuration_stack}") \
            && role_arn=$(get_role_arn "${configuration_stack}") \
            || return 1

    # build sam templates if present
    templates=$(sambuild "${bucket}")

    # ensure next commans are run from SCRIPTPATH
    cd "${SCRIPTPATH}" || return 1

    cfn_input_template="${BUILDPATH}/main.yaml"

    # Copy or update files in S3 bucket created by the configuration stack
    aws s3 sync ${PROFILE_STR} \
        "${BUILDPATH}" \
        s3://"${bucket}/app" \
        --exclude "*.aws-*"

    # deploy cloudformation application stack
    aws cloudformation deploy ${PROFILE_STR} \
        --template-file "${cfn_input_template}" \
        --role-arn "${role_arn}" \
        --stack-name "${application_stack}" \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
        --parameter-overrides \
            S3BucketName="${bucket}" \
            S3BucketSecureURL="${bucket_url}/app" \
            IAMServiceRole="${role_arn}" \
            LastChange=`date +%Y%m%d%H%M%S`

    # Get stackoutputs of MainStack -- allow jq to fail if none are found
    outputs=$(\
        aws cloudformation describe-stacks ${PROFILE_STR} \
            --stack-name "${application_stack}" \
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

function create_buildpath(){
    # Create ./build path and .gitignore

    cd "${SCRIPTPATH}" || return 1

    if [ ! -d "./build" ];then
        (
            mkdir -p "./build" \
            || return 1
        )
    fi
    # ensure files under ./build are ignored by git
    cat << IGNORE_FILE_BUILD >./build/.gitignore
# ignore everything under build
# build/* should only contain generated data
# this file is auto-generated by ${PROGNAME}
*
IGNORE_FILE_BUILD
    return $?
}

function create_configuration_template(){
    # dump configuration template under ./build
    template_name="${1}"

    [ -z "${template_name}" ] && return 1

    # ./build must exist
    create_buildpath || return 1

    # Validate path
    cd "${SCRIPTPATH}" || return 1

    # add configuration stack template to ./build
    cat << CONFIGURATION_STACK >./build/${template_name}
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

    # check if arguments follow a -${OPTION} ${VALUE} pattern
    sequence=0
    for param in $@;do
        sequence=$((sequence+1))
        [ "$((sequence%2))" -eq 0 ] && continue
        if [ ! "${param:0:1}" = "-" ];then
            usage
            exit 1
        fi
    done

    # extract valid options
    while getopts "c:a:p:r:f:w" opt;do
        case "$opt" in
            c)  export _CONFIGURATION_STACKNAME="$OPTARG";;
            a)  export _APPLICATION_STACKNAME="$OPTARG";;
            p)  export _AWS_PROFILE="$OPTARG";;
            r)  export _AWS_DEFAULT_REGION="$OPTARG";;
            w)  [ ! -z "${REPOSITORY}" ] && [ -d "${REPOSITORY}/.git" ] \
                    && export AUTO_COMMIT="true";;
            f) export ENVIRONMENT_FILE="$OPTARG";;
            *)  usage; exit 1;;
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

    export BUILDPATH="${SCRIPTPATH}/build/current/app"

    # Optional. If environment file is passed, load variables from file
    if [ ! -z "${ENVIRONMENT_FILE}" ];then
        if [ -s "${ENVIRONMENT_FILE}" ];then
            echo "Loading: ${ENVIRONMENT_FILE}"
            # - source relevant variables -- AWS_* and vars that can be overriden
            # - stick with sed to limit script dependencies
            export $(
                sed -n \
                    '/^AWS_[A-Z_]*=.*$/p;
                    /^CONFIGURATION_STACKNAME=.*$/p;
                    /^APPLICATION_STACKNAME=.*$/p;
                    /^TEMPLATE_FILE=.*$/p' \
                "${ENVIRONMENT_FILE}"
            )
        else
            echo "File \"${ENVIRONMENT_FILE}\" is empty or does not exist"
        fi
    fi

    # copy from CLI if set earlier -- this has precedence over ENVIRONMENT_FILE
    [ ! -z "${_AWS_PROFILE}" ] && export AWS_PROFILE="${_AWS_PROFILE}"
    [ ! -z "${_CONFIGURATION_STACKNAME}" ] \
        && export CONFIGURATION_STACKNAME="${_CONFIGURATION_STACKNAME}"
    [ ! -z "${_APPLICATION_STACKNAME}" ] \
        && export APPLICATION_STACKNAME="${_APPLICATION_STACKNAME}"
    [ ! -z "${_AWS_DEFAULT_REGION}" ] \
        && export AWS_DEFAULT_REGION="${_AWS_DEFAULT_REGION}"

    if [ -z "${CONFIGURATION_STACKNAME}" ];then
        # generate based on directory-name
        export CONFIGURATION_STACKNAME="$(basename "${SCRIPTPATH}")"
    fi

    if [ -z "${APPLICATION_STACKNAME}" ];then
        # generate based on directory-name
        export APPLICATION_STACKNAME="$(basename "${SCRIPTPATH}")"
        if [ ! -z "${REPOSITORY}" ];then
            export APPLICATION_STACKNAME="$(git_namestring)"
        else
            export APPLICATION_STACKNAME="$(basename "${SCRIPTPATH}")"
        fi
    fi
    # Ensure Stackname fits CloudFormation naming scheme
    export CONFIGURATION_STACKNAME=$(process_stackname "${CONFIGURATION_STACKNAME}")
    export APPLICATION_STACKNAME=$(process_stackname "${APPLICATION_STACKNAME}")

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

if [ -z "${action}" ];then
    usage
    exit 1
fi

case "${action}" in
    --deploy|--delete|--checkout)
        # repository (url, directory) expected -- defaults to "."
        shift
        repository="${1}"

        # empty or "-" are invalid invalid, likely an input error
        if [ -z "${repository}" ] || [ "${repository:0:1}" = "-" ];then
            usage
            exit 1
        fi
        # for all other input, assume repository input is valid 
        # nothing bad happens if its not
        export REPOSITORY="${repository}"
        ;;
esac


# ensure essential variables are set in environment
shift
parse_opts $@
set_defaults

case "${action}" in
    --deploy)
        validate_auto_commit \
            && update_from_git \
            && deploy
        ;;
    --checkout) 
        validate_auto_commit || exit 1
        if [ ! -d ".git" ];then
            git config --global user.useConfigOnly true
            if [ "${repository}" = "." ];then
                git init
            else
                git init \
                    && git checkout -b trunk \
                    && git remote add origin "${REPOSITORY}" \
                    && git fetch \
                    && git_auto_commit \
                    && git checkout master \
                    && git merge trunk \
                            --allow-unrelated-histories \
                            -m "__auto_update__:$(date +%s)"
            fi
        fi
        ;;
    --delete)   
        delete_application;;
    --deploy_configuration)
        # name tied to stack-/ dirname
        deploy_configuration;;
    --delete_configuration)
        # name tied to stack-/ dirname
        delete_configuration;;
    --status)   
        status;;
    --validate_account)
        validate_account;;
    --help)     
        usage;;
    *)
        usage;;
esac
exit $?

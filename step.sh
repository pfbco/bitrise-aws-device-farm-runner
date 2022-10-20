#!/bin/bash

THIS_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

set -e

# Uncomment for easier debugging:
#set -x

#=======================================
# Functions
#=======================================

RESTORE='\033[0m'
RED='\033[00;31m'
YELLOW='\033[00;33m'
BLUE='\033[00;34m'
GREEN='\033[00;32m'

function color_echo {
    color=$1
    msg=$2
    echo -e "${color}${msg}${RESTORE}"
}

function echo_fail {
    msg=$1
    echo
    color_echo "${RED}" "${msg}"
    exit 1
}

function echo_warn {
    msg=$1
    color_echo "${YELLOW}" "${msg}"
}

function echo_info {
    msg=$1
    echo
    color_echo "${BLUE}" "${msg}"
}

function echo_details {
    msg=$1
    echo "  ${msg}"
}

function echo_done {
    msg=$1
    color_echo "${GREEN}" "  ${msg}"
}

function validate_required_variable {
    key=$1
    value=$2
    if [ -z "${value}" ] ; then
        echo_fail "[!] Variable: ${key} cannot be empty."
    fi
}

function validate_required_input {
    key=$1
    value=$2
    if [ -z "${value}" ] ; then
        echo_fail "[!] Missing required input: ${key}"
    fi
}

function validate_required_input_with_options {
    key=$1
    value=$2
    options=$3

    validate_required_input "${key}" "${value}"

    found="0"
    for option in "${options[@]}" ; do
        if [ "${option}" == "${value}" ] ; then
            found="1"
        fi
    done

    if [ "${found}" == "0" ] ; then
        echo_fail "Invalid input: (${key}) value: (${value}), valid options: ($( IFS=$", "; echo "${options[*]}" ))"
    fi
}

function validate_ios_inputs {
    validate_required_input "ipa_path" "${ipa_path}"
    validate_required_input "ios_pool" "${ios_pool}"
}

function validate_android_inputs {
    validate_required_input "apk_path" "${apk_path}"
    validate_required_input "android_pool" "${android_pool}"
}

function get_test_package_arn {
    # Get most recent test bundle ARN
    set +o errexit
    validate_required_variable "test_package_name" "${test_package_name}"
    test_package_arn=$(set -eu; set -o pipefail; aws devicefarm list-uploads --arn="$device_farm_project" --query="uploads[?name=='${test_package_name}'] | max_by(@, &created).arn" --output=json | jq -r .)
    if [[ "$?" -ne 0 ]]; then
        echo_fail "Unable to find a test package named '${test_package_name}' in your device farm project. Please make sure that test_package_name corresponds to the basename (not the full path) of the test package which should have been previously uploaded by the aws-file-deploy step. If the test bundle is too old it may not be found; try re-uploading it. See https://github.com/peartherapeutics/bitrise-aws-device-farm-file-deploy"
    fi
    set -o errexit
}

function get_upload_status {
    local upload_arn="$1"
    validate_required_variable "upload_arn" "${upload_arn}"

    local upload_status
    upload_status=$(set -eu; aws devicefarm get-upload --arn="$upload_arn" --query='upload.status' --output=text)
    echo "$upload_status"
}

function get_run_result {
    local run_arn="$1"
    validate_required_variable "run_arn" "${run_arn}"

    local run_result
    run_result=$(set -eu; aws devicefarm get-run --arn="$run_arn" --query='run.result' --output=text)
    echo "$run_result"
}

function get_run_final_result {
    local run_arn="$1"
    validate_required_variable "run_arn" "${run_arn}"

    local run_final_details
    run_final_details=$(set -eu; aws devicefarm get-run --arn="$run_arn" --output=json)
    local run_final_details_minutes
    run_final_details_minutes=$(set -eu; echo "${run_final_details}" | jq -r .run.deviceMinutes.total)
    local run_final_details_completed_jobs
    run_final_details_completed_jobs=$(set -eu; echo "${run_final_details}" | jq -r .run.completedJobs)
    local run_final_details_total_jobs
    run_final_details_total_jobs=$(set -eu; echo "${run_final_details}" | jq -r .run.totalJobs)
    local run_final_details_summary
    run_final_details_summary="Devicefarm performed ${run_final_details_completed_jobs}/${run_final_details_total_jobs} jobs. Total time ${run_final_details_minutes} minutes."

    # Output in build log
    echo_details "$run_final_details"
    echo_details "$run_final_details_summary"

    # Export results to be used in subsequent notification steps
    envman add --key BITRISE_DEVICEFARM_RESULTS_RAW --value "$run_final_details"
    envman add --key BITRISE_DEVICEFARM_RESULTS_SUMMARY --value "$run_final_details_summary"

}

function device_farm_run {
    local run_platform="$1"
    local device_pool="$2"
    local app_package_path="$3"
    local upload_type="$4"

    set +o errexit
    set +o nounset

    echo_info "Setting up device farm run for platform '$run_platform'."

    echo_details "* run_platform: $run_platform"
    echo_details "* device_pool: $device_pool"
    echo_details "* app_package_path: $app_package_path"
    echo_details "* upload_type: $upload_type"
    echo_details "* test_package_arn: $test_package_arn"

    validate_required_variable "run_platform" "${run_platform}"
    validate_required_variable "device_pool" "${device_pool}"
    validate_required_variable "app_package_path" "${app_package_path}"
    validate_required_variable "upload_type" "${upload_type}"
    validate_required_variable "test_package_arn" "${test_package_arn}"

    set -o errexit
    set -o nounset
    set -o pipefail

    # Intialize upload
    local app_filename
    app_filename=$(set -eu; basename "$app_package_path")
    local create_upload_response
    create_upload_response=$(set -eu; aws devicefarm create-upload --project-arn="$device_farm_project" --name="$app_filename" --type="$upload_type" --query='upload.[arn, url]' --output=text)
    local app_arn
    app_arn=$(set -eu; echo $create_upload_response|cut -d' ' -f1)
    local app_upload_url
    app_upload_url=$(set -eu; echo $create_upload_response|cut -d' ' -f2)
    echo_details "Initialized upload of package '$app_filename' for app ARN '$app_arn'"

    # Perform upload
    echo_details "Beginning upload"
    curl -T "$app_package_path" "$app_upload_url"
    echo_details "Upload finished. Polling for status."

    # Poll for successful upload
    local upload_status
    upload_status=$(set -eu; get_upload_status "$app_arn")
    echo_details "Upload status: $upload_status"
    while [ ! "$upload_status" == 'SUCCEEDED' ]; do
        if [ "$upload_status" == 'FAILED' ]; then
            echo_fail 'Upload failed!'
        fi

        echo_details "Upload not yet processed; waiting. (Status=$upload_status)"
        sleep 10
        upload_status=$(set -eu; get_upload_status "$app_arn")
    done
    echo_details 'Upload successful! Starting run...'

    # Start run
    local run_params=(--project-arn="$device_farm_project")
    run_params+=(--device-pool-arn="$device_pool")
    run_params+=(--configuration="{\"billingMethod\": \"${billing_method}\", \"locale\": \"${locale}\"}")
    run_params+=(--app-arn="$app_arn")
    run_params+=(--output=json)

    local test_params=''
    test_params+="{\"type\": \"${test_type}\",\"testPackageArn\": \"${test_package_arn}\""
    if [[ -n "$filter" ]]; then
        test_params+=",\"filter\": \"${filter}\""
    fi
    if [[ -n "$test_spec" ]]; then
        test_params+=",\"testSpecArn\": \"${test_spec}\""
    fi
    test_params+=",\"parameters\": {\"TestEnvVar\": \"foo\"}}"
    run_params+=(--test="$test_params")

    if [ -n "$run_name_prefix" ]; then
        local run_name="${run_name_prefix}_${run_platform}_${build_version}"
        run_params+=(--name="$run_name")
        echo_details "Using run name '$run_name'"
    fi

    local run_response
    echo "aws devicefarm schedule-run "${run_params[@]}" --output=json"
    run_response=$(set -eu; aws devicefarm schedule-run "${run_params[@]}" --output=json)
    echo_info "Run started for $run_platform!"
    echo_details "Run response: '${run_response}'"

    # Depending on user parameters, we either wait and poll devicefarm for the
    # test results, or we skip past leaving it up to the user to follow up the
    # status of the tests.
    if [ "$run_wait_for_results" == 'true' ]; then

        # Obtain the ARN for the run from the schedule-run request
        local run_arn
        run_arn=$(set -eu; echo "${run_response}" | jq -r .run.arn)

        # Poll for the run result. This can often take a few minutes depending on
        # how sophisticated the test suite is and how many devices have been
        # selected. Note that run result is different to run status.
        local run_result="PENDING"
        echo_details "Waiting for run to complete. This can take a while..."
        while [ ! "$run_result" == 'PASSED' ]; do
            if [ "$run_result" == 'FAILED' ]; then
                get_run_final_result "$run_arn"
                echo_fail 'Run failed (result == FAILED)'
            fi
            if [ "$run_result" == 'SKIPPED' ]; then
                get_run_final_result "$run_arn"
                echo_fail 'Run failed (result == SKIPPED)'
            fi
            if [ "$run_result" == 'ERRORED' ]; then
                get_run_final_result "$run_arn"
                echo_fail 'Run failed (result == ERRORED)'
            fi
            if [ "$run_result" == 'STOPPED' ]; then
                get_run_final_result "$run_arn"
                echo_fail 'Run failed (result == STOPPED)'
            fi
            if [ "$run_result" == 'WARNED' ]; then
                # Not all people will want a WARNED state to count as failed, so
                # this option has been made configurable.
                if [ "$run_fail_on_warning" == 'true' ]; then
                    get_run_final_result "$run_arn"
                    echo_fail 'Run failed (result == WARNED)'
                else
                  echo_details "Run returned WARNED, passing as successful"
                  break
                fi
            fi

            echo_details "Run not yet completed; waiting. (Status=$run_result)"
            sleep 30
            run_result=$(set -eu; get_run_result "$run_arn")
        done

        # Run completed successfully. Obtain the full run details.
        echo_details 'Run successful!'
        get_run_final_result "$run_arn"
    else
      echo_details 'Run submitted to Devicefarm successfully. Please check results.'
    fi
}

function device_farm_run_ios {
    device_farm_run ios "$ios_pool" "$ipa_path" IOS_APP
}

function device_farm_run_android {
    device_farm_run android "$android_pool" "$apk_path" ANDROID_APP
}

#=======================================
# Main
#=======================================

#
# Validate parameters
echo_info "Configs:"
if [[ -n "$access_key_id" ]] ; then
    echo_details "* access_key_id: ***"
else
    echo_details "* access_key_id: [EMPTY]"
fi
if [[ -n "$secret_access_key" ]] ; then
    echo_details "* secret_access_key: ***"
else
    echo_details "* secret_access_key: [EMPTY]"
fi
echo_details "* device_farm_project: $device_farm_project"
echo_details "* test_package_name: $test_package_name"
echo_details "* test_type: $test_type"
echo_details "* filter: $filter"
echo_details "* test_spec: $test_spec"
echo_details "* billing_method: $billing_method"
echo_details "* locale: $locale"
echo_details "* platform: $platform"
echo_details "* ipa_path: $ipa_path"
echo_details "* ios_pool: $ios_pool"
echo_details "* apk_path: $apk_path"
echo_details "* android_pool: $android_pool"
echo_details "* run_name_prefix: $run_name_prefix"
echo_details "* build_version: $build_version"
echo_details "* aws_region: $aws_region"
echo_details "* run_wait_for_results: $run_wait_for_results"
echo_details "* run_fail_on_warning: $run_fail_on_warning"
echo

validate_required_input "access_key_id" "${access_key_id}"
validate_required_input "secret_access_key" "${secret_access_key}"
validate_required_input "device_farm_project" "${device_farm_project}"
validate_required_input "test_package_name" "${test_package_name}"
validate_required_input "test_type" "${test_type}"

options=("METERED" "UNMETERED")
validate_required_input_with_options "billing_method" "${billing_method}" "${options[@]}"

options=("ar_IL" "bg_BG" "ca_ES" "zh_CN" "zh_TW" "hr_HR" "cs_CZ" "da_DK" "nl_BE" "nl_NL" "en_AU" "en_GB" "en_CA" "en_IE" "en_IN" "en_NZ" "en_US" "fi_FI" "fr_BE" "fr_CA" "fr_FR" "fr_CH" "de_AT" "de_DE" "de_LI" "de_CH" "el_GR" "he_IL" "hi_IN" "hu_HU" "id_ID" "it_IT" "it_CH" "ja_JP" "ko_KR" "lv_LV" "lt_LT" "nb_NO" "pl_PL" "ro_RO" "ru_RU" "sr_RS" "sk_SK" "sl_SI" "es_ES" "es_US" "sv_SE" "tl_PH" "th_TH" "tr_TR" "uk_UA" "vi_VN")
validate_required_input_with_options "locale" "${locale}" "${options[@]}"

options=("ios"  "android" "ios+android")
validate_required_input_with_options "platform" "${platform}" "${options[@]}"

if [[ "$aws_region" != "" ]] ; then
    echo_details "AWS region (${aws_region}) specified!"
    export AWS_DEFAULT_REGION="${aws_region}"
fi

export AWS_ACCESS_KEY_ID="${access_key_id}"
export AWS_SECRET_ACCESS_KEY="${secret_access_key}"

set -o errexit
set -o pipefail

if [ "$platform" == 'ios' ]; then
    validate_ios_inputs
    set -o nounset
    get_test_package_arn
    device_farm_run_ios
elif [ "$platform" == 'android' ]; then
    validate_android_inputs
    set -o nounset
    get_test_package_arn
    device_farm_run_android
elif [ "$platform" == 'ios+android' ]; then
    validate_ios_inputs
    validate_android_inputs
    set -o nounset
    get_test_package_arn
    device_farm_run_ios
    device_farm_run_android
fi

echo_info 'Done!'

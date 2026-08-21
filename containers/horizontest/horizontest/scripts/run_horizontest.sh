#!/bin/sh

set -x

HORIZONTEST_DIR=/var/lib/horizontest
HORIZON_LOGS_DIR_NAME=${HORIZON_LOGS_DIR_NAME:-"horizon"}
IMAGE_URL=http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img
PROJECT_NAME=horizontest
USER_NAME=horizontest
PASSWORD=horizontest
FLAVOR_NAME=m1.tiny
GROUP_NAME=admins
SELENIUM_MESSAGE_WAIT=120
SELENIUM_EXPLICIT_WAIT=360
SELENIUM_PAGE_TIMEOUT=240
SELENIUM_IMPLICIT_WAIT=30
HORIZONTEST_DEBUG_MODE="${HORIZONTEST_DEBUG_MODE:-false}"
EXTRA_FLAG="${EXTRA_FLAG:-"not pagination and not federation"}"
PROJECT_NAME_XPATH="${PROJECT_NAME_XPATH:-"//span[@class='rcueicon rcueicon-folder-open']/ancestor::li"}"
IMAGE_FILE_NAME=cirros-0.6.2-x86_64-disk
IMAGE_FILE_NAME_WITH_SIZE="cirros-0.6.2-x86_64-disk (20.4 MB)"
IMAGE_FILE="/usr/local/share/${IMAGE_FILE_NAME}"
if [[ ! -f "${IMAGE_FILE}" ]]; then
    IMAGE_FILE="/var/lib/horizontest/${IMAGE_FILE_NAME}"
fi
SUBNET_NAME=public_subnet
HELP_SEQUENCE=".//*[normalize-space()='Help']"
HELP_URL="https://docs.redhat.com/en/documentation/red_hat_openstack_services_on_openshift/"
TEST_MATERIAL_THEME=False
USER_NAME_XPATH="//span[@class='rcueicon rcueicon-user']/ancestor::li"
BROWSE_LEFT_PANEL_MAIN="Project,Project,Project,Project,Project,Project,Project,Project,Project,Project,Project,Project,Project,Project,Project,Project,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Admin,Identity,Identity,Identity,Identity,Identity"
BROWSE_LEFT_PANEL_SEC="Project,None,None,None,None,None,Volumes,Volumes,Network,Network,Network,Network,Network,Network,Network,Object Store,None,Compute,Compute,Compute,Compute,Compute,Volume,Volume,Volume,Volume,Network,Network,Network,Network,Network,System,System,System,None,None,None,None,None"
BLP_SEC_LINE_XPATH=".//*[@class='navbar primary persistent-secondary']"
BLP_SEC_LINE_REQ_BTN=".//*[@class='navbar primary persistent-secondary']//a[normalize-space()='{sec_panel}']//ancestor::li"
BLP_SIDEBAR_XPATH=".//*[@class='navbar primary persistent-secondary']//a[normalize-space()='{sec_panel}']//ancestor::li//*[@class='dropdown-menu']"
PROJECT_TEXT_XPATH="${PROJECT_TEXT_XPATH:-".//span[@class='rcueicon rcueicon-folder-open']/ancestor::li"}"
SERVICES_REGION_NAME_XPATH=".//li[@id='services_region_switcher']/a"
SERVICES_REGION_BTN_TEXT_PATTERN="Managing Region {region}"
SERVICES_REGION_DROPDOWN_XPATH=".//li[@id='services_region_switcher']"

# assert mandatory variables have been set
if [[ -z "${ADMIN_USERNAME}" ]]; then
    ADMIN_USERNAME=$(python3 -c "from openstack.config import OpenStackConfig; print(OpenStackConfig().get_one(cloud='default').auth['username'])")
fi
if [[ -z "${ADMIN_PASSWORD}" ]]; then
    ADMIN_PASSWORD=$(python3 -c "from openstack.config import OpenStackConfig; print(OpenStackConfig().get_one(cloud='default').auth['password'])")
fi
[[ -z ${DASHBOARD_URL} ]] && echo "DASHBOARD_URL not set" && exit 1
[[ -z ${AUTH_URL} ]] && echo "AUTH_URL not set" && exit 1
[[ -z ${REPO_URL} ]] && REPO_URL="https://review.opendev.org/openstack/horizon"
[[ -z ${HORIZON_REPO_BRANCH} ]] && HORIZON_REPO_BRANCH="master"

function catch_error_if_debug {
    echo "File run_horizontest.sh has run into an error!"
    sleep infinity
}

# Catch errors when in debug mode
if [ ${HORIZONTEST_DEBUG_MODE} == true ]; then
    trap catch_error_if_debug ERR
fi

#This function is temporarily added until tempest cleanup is implemented
function clean_leftover_images {
    openstack image list -c Name -f value --os-cloud default | xargs -I {} openstack image delete {} --os-cloud default
}

function create_custom_resources {
    if ! openstack image show --os-cloud default ${IMAGE_FILE_NAME} ; then
        if [ ! -f "$IMAGE_FILE" ]; then
            curl -o "$IMAGE_FILE" -OL ${IMAGE_URL}
        fi
        openstack image create \
                --os-cloud default \
                --disk-format qcow2 \
                --container-format bare \
                --file "$IMAGE_FILE" --public ${IMAGE_FILE_NAME}
    fi

    if ! openstack project show --os-cloud default ${PROJECT_NAME} ; then
        openstack project create \
                --os-cloud default \
                --description 'Horizon Selenium test project' ${PROJECT_NAME}
    fi

    if ! openstack user show --os-cloud default ${USER_NAME}; then
        openstack user create \
                --os-cloud default \
                --project ${PROJECT_NAME} \
                --password ${PASSWORD} ${USER_NAME}
    fi

    openstack role add \
            --os-cloud default \
            --user ${USER_NAME} \
            --project ${PROJECT_NAME} member

    if ! openstack flavor show --os-cloud default ${FLAVOR_NAME}; then
        openstack flavor create \
                --os-cloud default \
                --public ${FLAVOR_NAME} \
                --ram 512 --disk 1 --vcpus 1
    fi

    if ! openstack group show --os-cloud default ${GROUP_NAME}; then
        openstack group create \
                --os-cloud default ${GROUP_NAME}
    fi
}

function delete_custom_resources {
    if openstack image show --os-cloud default ${IMAGE_FILE_NAME}; then
        openstack image delete \
                --os-cloud default ${IMAGE_FILE_NAME}
    fi

    if openstack project show --os-cloud default ${PROJECT_NAME}; then
        openstack project delete \
                --os-cloud default ${PROJECT_NAME}
    fi

    if openstack user show --os-cloud default ${USER_NAME}; then
        openstack user delete \
                --os-cloud default ${USER_NAME}
    fi

    if openstack flavor show --os-cloud default ${FLAVOR_NAME}; then
        openstack flavor delete \
                --os-cloud default ${FLAVOR_NAME}
    fi

    if openstack group show --os-cloud default ${GROUP_NAME}; then
        openstack group delete \
                --os-cloud default ${GROUP_NAME}
    fi
}

pushd ${HORIZONTEST_DIR}
GIT_CMD_ARGS=()
if [[ ${REPO_URL} == *redhat.com* ]]; then
    GIT_CMD_ARGS+=(-c http.sslVerify=false)
fi

_trial=0
_limit=5
_delay=30

GIT_CLONE_CMD=(git "${GIT_CMD_ARGS[@]}" clone "${REPO_URL}" "${HORIZONTEST_DIR}/horizon")

until ("${GIT_CLONE_CMD[@]}"); do
    if [ "${_trial}" -lt "${_limit}" ]; then
        _trial=$(( _trial + 1 ))
        echo "Git clone failed; retrying in ${_delay} seconds..."
        sleep "${_delay}"
    else
        exit 1
    fi
done
chown -R horizontest:horizontest horizon
pushd horizon
git "${GIT_CMD_ARGS[@]}" pull --rebase
git checkout ${HORIZON_REPO_BRANCH}

clean_leftover_images
create_custom_resources
pushd ${HORIZONTEST_DIR}/horizon/openstack_dashboard/test/integration_tests/

# set variables in horizon.conf
crudini --set horizon.conf dashboard dashboard_url ${DASHBOARD_URL}/dashboard/
crudini --set horizon.conf dashboard auth_url ${AUTH_URL}
crudini --set horizon.conf dashboard help_url ${HELP_URL}
crudini --set horizon.conf identity username ${USER_NAME}
crudini --set horizon.conf identity password ${PASSWORD}
crudini --set horizon.conf identity home_project ${PROJECT_NAME}
crudini --set horizon.conf identity admin_username ${ADMIN_USERNAME}
crudini --set horizon.conf identity admin_password ${ADMIN_PASSWORD}
crudini --set horizon.conf image http_image ${IMAGE_URL}
crudini --set horizon.conf image images_list ${IMAGE_FILE_NAME}
crudini --set horizon.conf launch_instances image_name "${IMAGE_FILE_NAME_WITH_SIZE}"
crudini --set horizon.conf selenium message_wait ${SELENIUM_MESSAGE_WAIT}
crudini --set horizon.conf selenium explicit_wait ${SELENIUM_EXPLICIT_WAIT}
crudini --set horizon.conf selenium page_timeout ${SELENIUM_PAGE_TIMEOUT}
crudini --set horizon.conf selenium implicit_wait ${SELENIUM_IMPLICIT_WAIT}
crudini --set horizon.conf network subnet_name ${SUBNET_NAME}
crudini --set horizon.conf theme project_name_xpath "${PROJECT_NAME_XPATH}"
crudini --set horizon.conf theme help_sequence "${HELP_SEQUENCE}"
crudini --set horizon.conf theme test_material_theme "${TEST_MATERIAL_THEME}"
crudini --set horizon.conf theme user_name_xpath "${USER_NAME_XPATH}"
crudini --set horizon.conf theme browse_left_panel_main "${BROWSE_LEFT_PANEL_MAIN}"
crudini --set horizon.conf theme browse_left_panel_sec "${BROWSE_LEFT_PANEL_SEC}"
crudini --set horizon.conf theme b_l_p_sec_line_xpath "${BLP_SEC_LINE_XPATH}"
crudini --set horizon.conf theme b_l_p_sec_line_req_btn "${BLP_SEC_LINE_REQ_BTN}"
crudini --set horizon.conf theme b_l_p_sidebar_xpath "${BLP_SIDEBAR_XPATH}"
crudini --set horizon.conf theme project_text_xpath "${PROJECT_TEXT_XPATH}"
crudini --set horizon.conf services_regions region_name_xpath "${SERVICES_REGION_NAME_XPATH}"
crudini --set horizon.conf services_regions region_btn_text_pattern "${SERVICES_REGION_BTN_TEXT_PATTERN}"
crudini --set horizon.conf services_regions region_dropdown_xpath "${SERVICES_REGION_DROPDOWN_XPATH}"
popd

# run horizon selenium tests
INTEGRATION_TESTS=1 SELENIUM_HEADLESS=True pytest openstack_dashboard/test/selenium/integration/ -k "${EXTRA_FLAG}" \
        --junitxml="test_reports/ui_integration_test_results.xml" \
        --html="test_reports/ui_integration_test_results.html" --self-contained-html
RETURN_VALUE=$?

# copy logs to external_files
echo "Copying logs file"
LOG_DIR=${HORIZONTEST_DIR}/external_files/${HORIZON_LOGS_DIR_NAME}/
mkdir -p ${LOG_DIR}
cp -rf ${HORIZONTEST_DIR}/horizon/test_reports/* ${LOG_DIR}

delete_custom_resources

# Keep pod in running state when in debug mode
if [ ${HORIZONTEST_DEBUG_MODE} == true ]; then
    sleep infinity
fi

exit ${RETURN_VALUE}

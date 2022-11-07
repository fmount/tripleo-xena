# /usr/bin/zsh

WORKDIR=$HOME/devnull/osp-k8s-operators/dev_operator
SRC=$HOME/devnull/osp-k8s-operators/dev_operator/lib-common
GOROOT_DIR=/usr/lib/go/src/

OPENSTACK=/usr/bin/openstack
SAMPLES=$WORKDIR/samples

# An old workaround to include lib-common for not pushed changes
# This is still valid for multiple lib-common includes in go.mod
function sync_lib_common {
  sudo cp -R $SRC $GOROOT_DIR
}

function link_operator {
    local libcommon="github.com/openstack-k8s-operators/lib-common/modules/storage v0.0.0-00010101000000-000000000000"
    local OPERATOR_NAME=$1
    if [ -z "$OPERATOR_NAME" ]; then
        echo "link_operator <operator_name>"
    else
        echo "Linking operator $OPERATOR_NAME to $PWD/tmp"
        mkdir -p $PWD/tmp
        ln -s $WORKDIR/$OPERATOR_NAME  ./tmp/$OPERATOR_NAME

        # Update go.mod
        if [[ "$OPERATOR_NAME" == "lib-common" ]]; then
            sed -i $'/require/{a\tgithub.com/openstack-k8s-operators/lib-common/modules/storage v0.0.0-00010101000000-000000000000\n:a;n;ba}' go.mod
            go mod edit -replace github.com/openstack-k8s-operators/$OPERATOR_NAME/modules/storage=./tmp/$OPERATOR_NAME/modules/storage
        else
            go mod edit -replace github.com/openstack-k8s-operators/$OPERATOR_NAME/api=./tmp/$OPERATOR_NAME/api
        fi
    fi
    go mod tidy

}

function crd_del {
    for i in $WORKDIR/$OPERATOR_NAME/config/crd/bases/*; {
       oc create -f $i;
    }
}

function crd {
    ACTION="$1"
    local OPERATOR_NAME=$2
    if [ -z "$OPERATOR_NAME" ]; then
        echo "crd $ACTION <operator_name>"
    else
        # stat operator_name path first ?
        for i in $WORKDIR/$OPERATOR_NAME-operator/config/crd/bases/*; {
            oc $ACTION -f $i;
        }
    fi
}

function delete_crd {
    OPERATOR_NAME="$1"
    ACTION="delete"
    # call the crd function with the delete parameters
    crd "delete" $1
}

function create_crd {
    OPERATOR_NAME="$1"
    ACTION="create"
    # call the crd function with the create parameters
    crd "create" $1
}

function clean_pv {
    NODE_NAME=$(oc get node -o name -l node-role.kubernetes.io/worker | head -n 1)

    for i in $(oc get pv | grep -E "(Failed|Released)" | awk {'print $1'}); do
        oc patch pv $i --type='json' -p='[{"op": "remove", "path": "/spec/claimRef"}]';
    done

    # now, it's time to run a real clanup of the crc directory

    if [ -z "$NODE_NAME" ]; then
      echo "Unable to determine node name with 'oc' command."
      exit 1
    fi
    oc debug $NODE_NAME -T -- chroot /host /usr/bin/bash -c "for i in {1..6}; do echo \"deleting dir content /mnt/openstack/pv00\$i\"; rm -rf /mnt/openstack/pv00\$i/*; done"

}

function endpoint_create {
    region="regionOne"
    local service=$1
    if [ -z "$service" ]; then
        echo "build_ep <service_name>"
        return
    fi
    if [[ $service == "cinder" ]]; then
        path="v3/%(project_id)s"
        svc="cinderv3"
    fi
    for ep in admin internal public; do
        $OPENSTACK endpoint create --region $region $svc $ep "http://$service-$ep-openstack.apps-crc.testing/$path";
    done
}

function scale_operators {
    for op in openstack cinder glance placement; do
        oc scale deployment $op-operator-controller-manager --replicas=0
    done
}

# TEST OPERATORS

function test_cinder {
    local type=$1
    if [ -z "$type" ]; then
        echo "test_cinder <cinder_type>"
        echo "  |-> e.g., test_cinder ceph"
        return
    fi
    cinder type-create $type
    cinder type-list
    cinder type-key $type set volume_backend_name=$type
    sleep 2
    cinder create 1 --volume-type $type --name "$type"_disk
}

function test_glance {
    IMAGE=$SAMPLES/cirros-0.5.2-x86_64-disk.img
    openstack image create --disk-format qcow2 --container-format bare --file $IMAGE cirros-test
    sleep 5
    openstack image list
    openstack delete cirros-test
}

function test_glance_policies {
    echo "Building projects and users"
    openstack project create --description 'project a' project-a --domain default
    openstack project create --description 'project b' project-b --domain default
    openstack user create project-a-reader --password project-a-reader
    openstack user create project-b-reader --password project-b-reader
    openstack user create project-a-member --password project-a-member
    openstack user create project-b-member --password project-b-member

    echo "Building projects and users"
    openstack role add --user project-a-member --project project-a member
    openstack role add --user project-a-reader --project project-a reader

    openstack role add --user project-b-member --project project-b member
    openstack role add --user project-b-reader --project project-b reader
}

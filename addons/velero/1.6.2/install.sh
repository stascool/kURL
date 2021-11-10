# shellcheck disable=SC2148
function velero_pre_init() {
    if [ -z "$VELERO_NAMESPACE" ]; then
        VELERO_NAMESPACE=velero
    fi
    if [ -z "$VELERO_LOCAL_BUCKET" ]; then
        VELERO_LOCAL_BUCKET=velero
    fi
    # TODO (dans): make this configurable from the installer spec
    # if [ -z "$VELERO_REQUESTED_CLAIM_SIZE" ]; then
    #     VELERO_REQUESTED_CLAIM_SIZE="50Gi"
    # fi
}

# runs on first install, and on version upgrades only
function velero() {
    local src="$DIR/addons/velero/$VELERO_VERSION"
    local dst="$DIR/kustomize/velero"

    render_yaml_file "$src/tmpl-kustomization.yaml" > "$dst/kustomization.yaml"

    velero_binary

    determine_velero_pvc_size

    velero_install "$src" "$dst"

    velero_patch_restic_privilege "$src" "$dst"

    velero_kotsadm_restore_config "$src" "$dst"

    # always patch the velero and restic manifests to include the PVC case
    velero_patch_internal_pvc_snapshots "$src" "$dst"

    velero_patch_http_proxy "$src" "$dst"

    velero_change_storageclass "$src" "$dst"

    velero_migrate_from_object_store "$src" "$dst"

    kubectl apply -k "$dst"

    kubectl label -n default --overwrite service/kubernetes velero.io/exclude-from-backup=true

    # Bail if the migratoin fails, preventing the original object store from being deleted
    if [ "$WILL_MIGRATE_VELERO_OBJECT_STORE" = "1" ]; then
        logWarn "Velero will migrate from object store to pvc"
        try_5m velero_pvc_migrated
        logSuccess "Velero migration complete"
    fi

    # Patch snapshots volumes to "Retain" in case of deletion
    if kubernetes_resource_exists "$VELERO_NAMESPACE" pvc velero-internal-snapshots; then

        local velero_pv_name
        echo "Patching internal snapshot volume Reclaim Policy to RECLAIM"
        try_1m velero_pvc_bound
        velero_pv_name=$(kubectl get pvc velero-internal-snapshots -n ${VELERO_NAMESPACE} -ojsonpath='{.spec.volumeName}')
        kubectl patch pv "$velero_pv_name" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
    fi
}

function velero_join() {
    velero_binary
}

function velero_install() {
    local src="$1"
    local dst="$2"
    local has_secret

    # TODO: remove this from the migration
    # Pre-apply CRDs since kustomize reorders resources. Grep to strip out sailboat emoji.
    "$src"/assets/velero-v"${VELERO_VERSION}"-linux-amd64/velero install --crds-only | grep -v 'Velero is installed'

    local resticArg="--use-restic"
    if [ "$VELERO_DISABLE_RESTIC" = "1" ]; then
        resticArg=""
    fi

    # detect if we need to use object store or pvc
    local bslArgs="--no-default-backup-location"
    if ! kubernetes_resource_exists "$VELERO_NAMESPACE" backupstoragelocation default; then
        bslArgs="--provider replicated.com/pvc --bucket velero-internal-snapshots --backup-location-config storageSize=${VELERO_PVC_SIZE},resticRepoPrefix=/var/velero-local-volume-provider/velero-internal-snapshots/restic"
    fi

    # we only need a secret file if it's already set for some other provider (including legacy internal storage)
    local secretArgs="--no-secret"
    if kubernetes_resource_exists "$VELERO_NAMESPACE" secret cloud-credentials; then
        has_secret=true
        velero_credentials
        secretArgs="--secret-file velero-credentials"
    fi

    "$src"/assets/velero-v"${VELERO_VERSION}"-linux-amd64/velero install \
        $resticArg \
        $bslArgs \
        $secretArgs \
        --namespace $VELERO_NAMESPACE \
        --plugins velero/velero-plugin-for-aws:v1.2.0,velero/velero-plugin-for-gcp:v1.2.0,velero/velero-plugin-for-microsoft-azure:v1.2.0,replicated/local-volume-provider:v0.3.0,"$KURL_UTIL_IMAGE" \
        --use-volume-snapshots=false \
        --dry-run -o yaml > "$dst/velero.yaml" 

    if [ -n "$has_secret" ]; then
        rm velero-credentials
    fi
}

# This runs when re-applying the same version to a cluster
function velero_already_applied() {
    local src="$DIR/addons/velero/$VELERO_VERSION"
    local dst="$DIR/kustomize/velero"

    determine_velero_pvc_size

    # This function will copy the kustomization template from the file if we need a migration.
    velero_migrate_from_object_store "$src" "$dst"

    # If we need to migrate, we're going to need to basically reconstruct the original install 
    # underneath the migration
    if [ "$WILL_MIGRATE_VELERO_OBJECT_STORE" = "1" ]; then
        velero_binary 
        velero_install "$src" "$dst"
        velero_patch_restic_privilege "$src" "$dst"
        velero_kotsadm_restore_config "$src" "$dst"
        velero_patch_internal_pvc_snapshots "$src" "$dst"
        velero_patch_http_proxy "$src" "$dst"
    fi

    # If we didn't need to migrate, reset the kustomization file and only apply the configmap
    # This function will create a new, blank kustomization file.
    velero_change_storageclass "$src" "$dst"

    # In the case this is a rook re-apply, no changes might be required
    if [ -f "$dst/kustomization.yaml" ]; then
        kubectl apply -k "$dst"
    fi

    # Bail if the migratoin fails, preventing the original object store from being deleted
    if [ "$WILL_MIGRATE_VELERO_OBJECT_STORE" = "1" ]; then
        logWarn "Velero will migrate from object store to pvc"
        try_5m velero_pvc_migrated
        logSuccess "Velero migration complete"
    fi

    # Patch snapshots volumes to "Retain" in case of deletion
    if kubernetes_resource_exists "$VELERO_NAMESPACE" pvc velero-internal-snapshots && [ "$WILL_MIGRATE_VELERO_OBJECT_STORE" = "1" ]; then
        local velero_pv_name
        echo "Patching internal snapshot volume Reclaim Policy to RECLAIM"
        try_1m velero_pvc_bound
        velero_pv_name=$(kubectl get pvc velero-internal-snapshots -n ${VELERO_NAMESPACE} -ojsonpath='{.spec.volumeName}')
        kubectl patch pv "$velero_pv_name" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
    fi
}

# The --secret-file flag should be used so that the generated velero deployment uses the
# cloud-credentials secret. Use the contents of that secret if it exists to avoid overwriting
# any changes. 
function velero_credentials() {
    if kubernetes_resource_exists "$VELERO_NAMESPACE" secret cloud-credentials; then
        kubectl -n velero get secret cloud-credentials -ojsonpath='{ .data.cloud }' | base64 -d > velero-credentials
        return 0
    fi
}

function velero_patch_restic_privilege() {
    local src="$1"
    local dst="$2"

    if [ "${VELERO_DISABLE_RESTIC}" = "1" ]; then
        return 0
    fi

    if [ "${K8S_DISTRO}" = "rke2" ] || [ "${VELERO_RESTIC_REQUIRES_PRIVILEGED}" = "1" ]; then
        render_yaml_file "$src/restic-daemonset-privileged.yaml" > "$dst/restic-daemonset-privileged.yaml"
        insert_patches_strategic_merge "$dst/kustomization.yaml" restic-daemonset-privileged.yaml
    fi
}

function velero_binary() {
    local src="$DIR/addons/velero/$VELERO_VERSION"

    if ! kubernetes_is_master; then
        return 0
    fi

    if [ ! -f "$src/assets/velero.tar.gz" ] && [ "$AIRGAP" != "1" ]; then
        mkdir -p "$src/assets"
        curl -L "https://github.com/vmware-tanzu/velero/releases/download/v${VELERO_VERSION}/velero-v${VELERO_VERSION}-linux-amd64.tar.gz" > "$src/assets/velero.tar.gz"
    fi

    pushd "$src/assets" || exit 1
    tar xf "velero.tar.gz"
    if [ "$VELERO_DISABLE_CLI" != "1" ]; then
        cp velero-v${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/velero
    fi
    popd || exit 1
}

function velero_kotsadm_restore_config() {
    local src="$1"
    local dst="$2"

    render_yaml_file "$src/tmpl-kotsadm-restore-config.yaml" > "$dst/kotsadm-restore-config.yaml"
    insert_resources "$dst/kustomization.yaml" kotsadm-restore-config.yaml
}

function velero_patch_http_proxy() {
    local src="$1"
    local dst="$2"

    if [ -n "$PROXY_ADDRESS" ]; then
        render_yaml_file "$src/tmpl-velero-deployment-proxy.yaml" > "$dst/velero-deployment-proxy.yaml"
        insert_patches_strategic_merge "$dst/kustomization.yaml" velero-deployment-proxy.yaml
    fi

    if [ -n "$PROXY_ADDRESS" ] && [ "$VELERO_DISABLE_RESTIC" != "1" ]; then
        render_yaml_file "$src/tmpl-restic-daemonset-proxy.yaml" > "$dst/restic-daemonset-proxy.yaml"
        insert_patches_strategic_merge "$dst/kustomization.yaml" restic-daemonset-proxy.yaml
    fi
}

# If this cluster is used to restore a snapshot taken on a cluster where Rook or OpenEBS was the 
# default storage provisioner, the storageClassName on PVCs will need to be changed from "default"
# to "longhorn" by velero
# https://velero.io/docs/v1.6/restore-reference/#changing-pvpvc-storage-classes
function velero_change_storageclass() {
    local src="$1"
    local dst="$2"

    if kubectl get sc longhorn &> /dev/null && \
    [ "$(kubectl get sc longhorn -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}')" = "true" ]; then

        # when re-applying the same velero version, this might not exist.
        if [ ! -f "$dst/kustomization.yaml" ]; then
            cat > "$dst/kustomization.yaml" <<EOF
namespace: ${VELERO_NAMESPACE}

resources:
EOF
        fi

        render_yaml_file "$src/tmpl-change-storageclass.yaml" > "$dst/change-storageclass.yaml"
        insert_resources "$dst/kustomization.yaml" change-storageclass.yaml

    fi
}

function velero_migrate_from_object_store() {
    local src="$1"
    local dst="$2"

    # TODO (dans): remove this feature flag when/if we decide to ship migration
    if [ -z "$BETA_VELERO_MIGRATE_FROM_OBJECT_STORE" ]; then 
        return
    fi

    echo ****HERE*****
    # if there is still an object store, don't migrate. If KOTSADM_DISABLE_S# is set, force the migration
    if [ ! "$KOTSADM_DISABLE_S3" == 1 ] || [ -n "$ROOK_VERSION" ] || [ -n "$MINIO_VERSION" ]; then 
        echo ****EXIT*****
        return
    fi
    echo ****CONTINUE*****

    # if an object store isn't installed don't migrate
    # TODO (dans): this doeesn't support minio in a non-standard namespace
    if (! kubernetes_resource_exists rook-ceph deployment rook-ceph-rgw-rook-ceph-store-a) && (! kubernetes_resource_exists minio deployment minio); then 
        return
    fi

    echo ****WOW*****

    export VELERO_S3_HOST=
    export VELERO_S3_ACCESS_KEY_ID=
    export VELERO_S3_ACCESS_KEY_SECRET=
    if kubernetes_resource_exists rook-ceph deployment rook-ceph-rgw-rook-ceph-store-a; then 
        echo "Previous installation of Rook Ceph detected."
        VELERO_S3_HOST="rook-ceph-rgw-rook-ceph-store.rook-ceph"
        VELERO_S3_ACCESS_KEY_ID=$(kubectl -n rook-ceph get secret rook-ceph-object-user-rook-ceph-store-kurl -o yaml | grep AccessKey | head -1 | awk '{print $2}' | base64 --decode)
        VELERO_S3_ACCESS_KEY_SECRET=$(kubectl -n rook-ceph get secret rook-ceph-object-user-rook-ceph-store-kurl -o yaml | grep SecretKey | head -1 | awk '{print $2}' | base64 --decode)
    else 
        echo "Previous installation of Minio detected."
        VELERO_S3_HOST="minio.minio"
        VELERO_S3_ACCESS_KEY_ID=$(kubectl -n minio get secret minio-credentials -ojsonpath='{ .data.MINIO_ACCESS_KEY }' | base64 --decode)
        VELERO_S3_ACCESS_KEY_SECRET=$(kubectl -n minio get secret minio-credentials -ojsonpath='{ .data.MINIO_SECRET_KEY }' | base64 --decode)
    fi

    # If this is run through `velero_already_applied`, we need to create base kustomization file
    if [ ! -f "$dst/kustomization.yaml" ];then
        render_yaml_file "$src/tmpl-kustomization.yaml" > "$dst/kustomization.yaml"
    fi

    # TODO (dans): figure out if there is enough space create a new volume with all the snapshot data

    # create secret for migration init container to pull from object store
    render_yaml_file "$src/tmpl-s3-migration-secret.yaml" > "$dst/s3-migration-secret.yaml"
    insert_resources "$dst/kustomization.yaml" s3-migration-secret.yaml

    # create configmap that holds the migration script
    render_yaml_file "$src/tmpl-s3-migration-configmap.yaml" > "$dst/s3-migration-configmap.yaml"
    insert_resources "$dst/kustomization.yaml" s3-migration-configmap.yaml

    # add patch to add init container for migration
    render_yaml_file "$src/tmpl-s3-migration-deployment-patch.yaml" > "$dst/s3-migration-deployment-patch.yaml"
    insert_patches_strategic_merge "$dst/kustomization.yaml" s3-migration-deployment-patch.yaml

    # update the BackupstorageLocation
    render_yaml_file "$src/tmpl-s3-migration-bsl.yaml" > "$dst/s3-migration-bsl.yaml"
    insert_resources "$dst/kustomization.yaml" s3-migration-bsl.yaml

    export WILL_MIGRATE_VELERO_OBJECT_STORE="1"
}

# add patches for the velero and restic to the current kustomization file that setup the PVC setup like the 
# velero LVP plugin requires 
function velero_patch_internal_pvc_snapshots() {
    local src="$1"
    local dst="$2"

    # If we are migrating from Rook to Longhorn, longhorn is not yes the default storage class.
    export VELERO_PVC_STORAGE_CLASS="default" # this is the rook-ceph default storage class
    if [ -n "$LONGHORN_VERSION" ]; then
        export VELERO_PVC_STORAGE_CLASS="longhorn"
    fi

    # create the PVC
    render_yaml_file "$src/tmpl-internal-snaps-pvc.yaml" > "$dst/internal-snaps-pvc.yaml"
    insert_resources "$dst/kustomization.yaml" internal-snaps-pvc.yaml

    # add patch to add the pvc in the correct location for the velero deployment
    render_yaml_file "$src/tmpl-internal-snaps-deployment-patch.yaml" > "$dst/internal-snaps-deployment-patch.yaml"
    insert_patches_strategic_merge "$dst/kustomization.yaml" internal-snaps-deployment-patch.yaml

    # add patch to add the pvc in the correct location for the restic daemonset
    render_yaml_file "$src/tmpl-internal-snaps-ds-patch.yaml" > "$dst/internal-snaps-ds-patch.yaml"
    insert_patches_strategic_merge "$dst/kustomization.yaml" internal-snaps-ds-patch.yaml

}

function velero_pvc_bound() {
    kubectl get pvc velero-internal-snapshots -n ${VELERO_NAMESPACE} -oyaml | grep -q "phase: Bound"
}

function velero_pvc_exists() {
    kubectl -n "${VELERO_NAMESPACE}" get pvc velero-internal-snapshots &>/dev/null
}

# if the PVC size has already been set we should not reduce it
function determine_velero_pvc_size() {
    local velero_pvc_size="50Gi"
    if velero_pvc_exists; then
        velero_pvc_size=$( kubectl get pvc -n "${VELERO_NAMESPACE}" velero-internal-snapshots -o jsonpath='{.spec.resources.requests.storage}')
    fi

    export VELERO_PVC_SIZE=$velero_pvc_size
}

function velero_pvc_migrated() {
    velero_pod=$( kubectl get pods -n velero -l component=velero -o jsonpath='{.items[?(@.spec.containers[0].name=="velero")].metadata.name}')
    if kubectl -n velero logs "$velero_pod" -c migrate-s3  | grep -q "migration ran successfully" &>/dev/null; then
        return 0
    fi
    if kubectl -n velero logs "$velero_pod" -c migrate-s3  | grep -q "migration has already run" &>/dev/null; then
        return 0
    fi
    return 1
}

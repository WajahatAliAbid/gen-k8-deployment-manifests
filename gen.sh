#!/bin/bash
set -eo pipefail

if [ "$1" == "--help" ]; then
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --env                           Environment (required)"
    echo "  --app-name                      Application name (required)"
    echo "  --image                         Container image (required)"
    echo "  --image-pull-policy             Image pull policy (default: IfNotPresent)"
    echo "  --cpu                           CPU request (default: 100m)"
    echo "  --memory                        Memory request (default: 512Mi)"
    echo "  --cpu-limit                     CPU limit (default: same as request)"
    echo "  --memory-limit                  Memory limit (default: same as request)"
    echo "  --replicas                      Number of replicas (default: 1)"
    echo "  --max-replicas                  Max replicas for scaling (default: 1)"
    echo "  --ports                         Comma-separated list of container ports"
    echo "  --configmap-data                Comma-separated list of key=value pairs for ConfigMap"
    echo "                                  (e.g., --configmap-data key1=value1,key2=value2)"
    echo "  --configmap-template            ConfigMap template file alongside path to map config in the script"
    echo "  --configmap-volume-path         Path to ConfigMap template file for mounting as volume"
    echo "  --secret-data                   Comma-separated list of key=value pairs for Secret"
    echo "                                  (e.g., --secret-data secret1=value1,secret2=value2)"
    echo "  --service-type                  Service type (default: ClusterIP)"
    echo "                                  Valid values are: ClusterIP, NodePort, LoadBalancer, ExternalName"
    echo "  --service-ports                 Comma-separated list of ports for the Service (default: all ports from --ports)"
    echo "  --generate-deployment           Generate deployment manifest"
    echo "  --generate-service              Generate service manifest"
    echo "  --hpa-utilization-threshold     CPU and memory utilization target for HPA (default: 70)"
    echo "  --termination-grace-period      Grace period for pod termination (default: none)"
    echo "  --post-start-lifecycle-hook     Lifecycle hook to run after the container starts (default: none)"
    echo "  --pre-stop-lifecycle-hook       Lifecycle hook to run before the container stops (default: none)"
    echo "  --spread-pods-evenly            Spreds pods evenly across nodes (default: false)"
    echo "  --skip-empty                    Skip empty ConfigMap/Secret entries (default: false)"
    echo "  --out                           Output directory (default: ./dist)"
    echo "  --verbose                       Verbose mode (default: false)"
    exit 0
fi
_opt_cpu="100m"
_opt_memory="512Mi"
_opt_cpu_limit=""
_opt_memory_limit=""
_opt_output="$(pwd)/dist"
_opt_gen_deployment=false
_opt_gen_service=false
_opt_skip_empty=false
_opt_replicas=1
_opt_max_replicas=1
_opt_service_type="ClusterIP"
_opt_hpa_utilization_threshold=70
_opt_termination_grace_period=""
_opt_image_pull_policy="IfNotPresent"
_opt_post_start_lifecycle_hook=""
_opt_pre_stop_lifecycle_hook=""
_opt_spread_pods_evenly=false
declare -A configmap_data
declare -A secret_data
declare -A _opt_ports
declare -A _opt_service_ports

_opt_configmap_template_file=""
_opt_configmap_map_path=""
_opt_configmap_volume_path=""

_get_ports_array() {
    local _ports_string="$1"  # Input string of ports
    declare -n _result_array="$2"  # Name reference to the output array
    declare -A _data_array
    
    # If ports string contains a comma, split it into an array
    if [[ "$_ports_string" == *","* ]]; then
        IFS=',' read -ra _ports_data <<< "$_ports_string"
        for item in "${_ports_data[@]}"; do
            if [[ "$item" == *"="* ]]; then
                IFS='=' read -r key value <<< "$item"
                _data_array["$key"]="$value"
            else
                echo "Error: Port '$item' must be in name=port format when multiple ports are provided."
                # Optionally exit here, but can be commented for testing
                # exit 1
            fi
        done
    else
        if [[ "$_ports_string" == *"="* ]]; then
            IFS='=' read -r key value <<< "$_ports_string"
            _data_array["$key"]="$value"
        else
            _data_array["main"]="$_ports_string"
        fi
    fi

    # Pass the data back via reference
    for key in "${!_data_array[@]}"; do
        _result_array["$key"]="${_data_array[$key]}"
    done
}

while [ "$1" != "" ]; do
    case $1 in
        --env )
            shift; _opt_env=$1;;
        --app-name )
            shift; _opt_app_name=$1;;
        --image )
            shift; _opt_image=$1;;
        --cpu )
            shift; _opt_cpu=$1;;
        --memory )
            shift; _opt_memory=$1;;
        --cpu-limit )
            shift; _opt_cpu_limit=$1;;
        --memory-limit )
            shift; _opt_memory_limit=$1;;
        --replicas )
            shift; _opt_replicas=$1;;
        --max-replicas )
            shift; _opt_max_replicas=$1;;
        --ports )
            shift;
            _get_ports_array $1 _opt_ports;;
        --service-ports )
            shift; 
            _get_ports_array $1 _opt_service_ports;;
        --configmap-data )
            shift;
            # Handle --configmap-data parameter, which could be key or key=value pairs
            IFS=',' read -ra configmap_items <<< "$1"
            for item in "${configmap_items[@]}"; do
                if [[ "$item" == *"="* ]]; then
                    IFS='=' read -r key value <<< "$item"
                    configmap_data["$key"]="$value"
                else
                    configmap_data["$item"]=""
                fi
            done
            ;;
        --configmap-template )
            shift
            if [[ -z "$1" || -z "$2" ]]; then
                echo "Error: Missing arguments for --configmap-template" >&2
                exit 1
            fi
            _opt_configmap_template_file="$1"
            _opt_configmap_map_path="$2"
            # Check if _opt_configmap_template_file exists
            if [ ! -f "$_opt_configmap_template_file" ]; then
                echo "Error: Configmap template file $_opt_configmap_template_file does not exist" >&2
                exit 1
            fi
            shift
            ;;
        --configmap-volume-path )
            shift; _opt_configmap_volume_path=$1;;
        --secret-data )
            shift;
            # Handle --secret-data parameter, which could be key or key=value pairs
            IFS=',' read -ra secret_items <<< "$1"
            for item in "${secret_items[@]}"; do
                if [[ "$item" == *"="* ]]; then
                    IFS='=' read -r key value <<< "$item"
                    secret_data["$key"]="$value"
                else
                    secret_data["$item"]=""
                fi
            done
            ;;
        --service-type )
            shift; _opt_service_type=$1;;
        --generate-deployment )
            _opt_gen_deployment=true;;
        --generate-service )
            _opt_gen_service=true;;
        --spread-pods-evenly )
            _opt_spread_pods_evenly=true;;
        --hpa-utilization-threshold )
            shift; _opt_hpa_utilization_threshold=$1;;
        --termination-grace-period )
            shift; _opt_termination_grace_period=$1;;
        --image-pull-policy )
            shift; _opt_image_pull_policy=$1;;
        --post-start-lifecycle-hook )
            shift; _opt_post_start_lifecycle_hook=$1;;
        --pre-stop-lifecycle-hook )
            shift; _opt_pre_stop_lifecycle_hook=$1;;
        --skip-empty )
            _opt_skip_empty=true;;
        --out )
            shift; _opt_output=$1;;
        --verbose )
            set -x;;
        * )
            echo "$1 unknown parameter"
            exit 1
    esac
    shift
done

################# Setting Defaults ################
if [ -z "$_opt_cpu_limit" ]; then
    _opt_cpu_limit="$_opt_cpu"
fi
if [ -z "$_opt_memory_limit" ]; then
    _opt_memory_limit="$_opt_memory"
fi


if [ ${#_opt_service_ports[@]} -eq 0 ]; then
    for key in "${!_opt_ports[@]}"; do
        _opt_service_ports["$key"]="${_opt_ports[$key]}"
    done
fi

################ End Setting Defaults ################
################# Validation ################
# Check for required parameters
if [ -z "$_opt_env" ]; then
    echo "Error: --env is required"
    exit 1
fi

if [ -z "$_opt_app_name" ]; then
    echo "Error: --app-name is required"
    exit 1
fi

if [ -z "$_opt_image" ]; then
    echo "Error: --image is required"
    exit 1
fi

if [ -z "$_opt_cpu" ]; then
    echo "Error: --cpu is required"
    exit 1
fi

if [ -z "$_opt_memory" ]; then
    echo "Error: --memory is required"
    exit 1
fi

if [ -z "$_opt_replicas" ]; then
    echo "Error: --replicas is required"
    exit 1
fi

# termination grace period is not empty then make sure it's a postive integer
if [ -n "$_opt_termination_grace_period" ]; then
    if ! [[ "$_opt_termination_grace_period" =~ ^[0-9]+$ ]] || [ "$_opt_termination_grace_period" -lt 0 ]; then
        echo "Error: --termination-grace-period must be a non-negative integer"
        exit 1
    fi
    if [ "$_opt_termination_grace_period" -eq 0 ]; then
        echo "Error: --termination-grace-period cannot be 0"
        exit 1
    fi
fi

# Validate replicas as a positive integer
if ! [[ "$_opt_replicas" =~ ^[0-9]+$ ]] || [ "$_opt_replicas" -le 0 ]; then
    echo "Error: --replicas must be a positive integer"
    exit 1
fi

if [ -z "$_opt_max_replicas" ]; then
    echo "Error: --max-replicas is required"
    exit 1
fi

# Validate max-replicas as a positive integer
if ! [[ "$_opt_max_replicas" =~ ^[0-9]+$ ]] || [ "$_opt_max_replicas" -le 0 ]; then
    echo "Error: --max-replicas must be a positive integer"
    exit 1
fi

################# CPU Validation ################
validate_cpu() {
    local cpu_value=$1
    # Allow values like "100m", "1", "2.5", "500m" but disallow invalid formats
    if ! [[ "$cpu_value" =~ ^([0-9]+(\.[0-9]+)?m|[0-9]+(\.[0-9]+)?)$ ]]; then
        echo "Error: Invalid CPU value '$cpu_value'. Valid formats are '100m', '1', '2.5', '500m', etc."
        exit 1
    fi
}       
validate_cpu "$_opt_cpu"
validate_cpu "$_opt_cpu_limit"

################# Memory Validation ################
validate_memory() {
    local memory_value=$1
    if ! [[ "$memory_value" =~ ^[0-9]+(Mi|Gi|Ki|M|G|K)?$ ]]; then
        echo "Error: Invalid memory value for $memory_value. Must be in valid units like 512Mi, 1Gi, 1G, etc."
        exit 1
    fi
}
validate_memory "$_opt_memory"
validate_memory "$_opt_memory_limit"

# Validate port ranges if any ports are provided
if [ ${#_opt_ports[@]} -ne 0 ]; then
    for key in "${!_opt_ports[@]}"; do
        _port="${_opt_ports[$key]}"
        if ! [[ "$_port" =~ ^[0-9]+$ && "$_port" -ge 1 && "$_port" -le 65535 ]]; then
            echo "Error: Invalid port: $_port. Ports must be integers between 1 and 65535."
            exit 1
        fi
    done
fi

# Validate the output directory path
if [ ! -d "$_opt_output" ]; then
    # echo "WArning: Output directory '$_opt_output' does not exist."
    echo "Creating output directory."
    mkdir -p "$_opt_output"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create output directory."
        exit 1
    fi
fi

# Ensure that the environment name is alphanumeric and possibly with underscores/dashes
if ! [[ "$_opt_env" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: --env must be alphanumeric, and can contain underscores or dashes."
    exit 1
fi

_valid_Service_types=("ClusterIP" "NodePort" "LoadBalancer" "ExternalName")

# Check if --service-type is valid
if ! [[ " ${_valid_Service_types[@]} " =~ " $_opt_service_type " ]]; then
    echo "Error: Invalid --service-type '$_opt_service_type'. Valid values are: ${_valid_Service_types[@]}"
    exit 1
fi

# Validate service-ports to ensure they are part of the --ports list

# for key in "${!_opt_service_ports[@]}"; do
#     echo $key
#     # _port="${_opt_service_ports[$key]}"
#     # echo $_port
# done
if [ ${#_opt_service_ports[@]} -ne 0 ]; then
    all_ports_array=("${_opt_ports[@]}")
    for key in "${!_opt_service_ports[@]}"; do
        _port="${_opt_service_ports[$key]}"
        
        if ! [[ " ${all_ports_array[@]} " =~ " $_port " ]]; then
            echo "Error: Port $_port in --service-ports is not valid. It must be part of the --ports list."
            exit 1
        fi

        # check if key exists in _opt_ports
        if [ -z "${_opt_ports[$key]}" ]; then
            echo "Error: Port $_port in --service-ports is not valid. Port with key $key does not exist in --ports list."
            exit 1
        fi

        if [ "${_opt_service_ports[$key]}" != "${_opt_ports[$key]}" ]; then
            echo "Error: Port $_port in --service-ports does not match the corresponding port with key $key in --ports."
            exit 1
        fi
    done
fi

# Validate HPA utilization threshold (1-100)
if [ -n "$_opt_hpa_utilization_threshold" ]; then
    if ! [[ "$_opt_hpa_utilization_threshold" =~ ^[0-9]+$ ]] || [ "$_opt_hpa_utilization_threshold" -lt 1 ] || [ "$_opt_hpa_utilization_threshold" -gt 100 ]; then
        echo "Error: --hpa-utilization-threshold must be a positive integer between 1 and 100."
        exit 1
    fi
fi

# Validate image pull policy
if ! [[ "$_opt_image_pull_policy" =~ ^(Never|IfNotPresent|Always)$ ]]; then
    echo "Error: Invalid --image-pull-policy '$_opt_image_pull_policy'. Valid values are: Never, IfNotPresent, Always."
    exit 1
fi
################## End Validation ################

echo "Environment: $_opt_env"
echo "Application: $_opt_app_name"

generate_deployment() {
    # if ports is not empty string then build ports string for deployment
    if [ ${#_opt_ports[@]} -gt 0 ]; then
        _deployment_ports="
        ports:"
        for key in "${!_opt_ports[@]}"; do
            _port="${_opt_ports[$key]}"
            _deployment_ports+="
          - name: $key
            containerPort: $_port"
        done
    else
        _deployment_ports=""
    fi
    _env_from=""
    if [[ ( "$_gen_configmap" == true && -n "$_opt_configmap_template_file" ) || "$_gen_secrets" == true ]]; then
        _env_from="envFrom:"

        if [  -z "$_opt_configmap_template_file" ]; then
            if [ "$_gen_configmap" == true ]; then
                _env_from+="
  - configMapRef:
      name: $_opt_env-$_opt_app_name"
            fi
        fi

        if [ "$_gen_secrets" == true ]; then
            _env_from+="
  - secretRef:
      name: $_opt_env-$_opt_app_name"
        fi
    fi
    _volumes=""
    _volume_mounts=""
    if [ "$_gen_configmap" == true ]; then
        if [ -n "$_opt_configmap_template_file" ]; then
            _volumes="volumes:
  - name: config-volume
    configMap:
      name: $_opt_env-$_opt_app_name"
            if [ -n "$_opt_configmap_volume_path" ]; then
                _volume_mounts="volumeMounts:
  - name: config-volume
    mountPath: $_opt_configmap_volume_path/$_opt_configmap_map_path
    subPath: $_opt_configmap_map_path"
            fi
        fi
    fi
    # Lifecycle hooks setup
    if [ -n "$_opt_pre_stop_lifecycle_hook" ]; then
        if [ -f "$_opt_pre_stop_lifecycle_hook" ]; then
            _pre_stop_lifecycle_hook="$(cat "$_opt_pre_stop_lifecycle_hook")"
        else
            _pre_stop_lifecycle_hook="$_opt_pre_stop_lifecycle_hook"
        fi
    fi

    if [ -n "$_opt_post_start_lifecycle_hook" ]; then
        if [ -f "$_opt_post_start_lifecycle_hook" ]; then
            _post_start_lifecycle_hook="$(cat "$_opt_post_start_lifecycle_hook")"
        else
            _post_start_lifecycle_hook="$_opt_post_start_lifecycle_hook"
        fi
    fi

    if [ -n "$_pre_stop_lifecycle_hook" ] || [ -n "$_post_start_lifecycle_hook" ]; then
        _lifecycle_policy="lifecycle:"
        if [ -n "$_pre_stop_lifecycle_hook" ]; then
            _lifecycle_policy+="
  preStop:
    exec:
      command:
        - /bin/sh
        - -c
        - |
$(echo "$_pre_stop_lifecycle_hook" | awk '{print "          " $0}')
"
        fi
        if [ -n "$_post_start_lifecycle_hook" ]; then
            _lifecycle_policy+="
  postStart:
    exec:
      command:
        - /bin/sh
        - -c
        - |
$(echo "$_post_start_lifecycle_hook" | awk '{print "          " $0}')
"
        fi
    fi
    _pod_anti_affinity=""
    if [ "$_opt_spread_pods_evenly" == true ]; then
        _pod_anti_affinity="
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values:
            - $_opt_app_name
          - key: env
            operator: In
            values:
            - $_opt_env
        topologyKey: kubernetes.io/hostname"
    fi
    echo "Generating Deployment"
    cat <<EOF >$_opt_output/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $_opt_env-$_opt_app_name
  namespace: $_opt_env
  labels:
    app: $_opt_app_name
    env: $_opt_env
spec:
  replicas: $_opt_replicas
  selector:
    matchLabels:
      app: $_opt_app_name
      env: $_opt_env
  template:
    metadata:
      labels:
        app: $_opt_app_name
        env: $_opt_env
    spec:
      $(if [ -n "$_opt_termination_grace_period" ]; then echo "terminationGracePeriodSeconds: $_opt_termination_grace_period"; fi)
      containers:
      - name: $_opt_app_name
        image: $_opt_image
        imagePullPolicy: $_opt_image_pull_policy
        resources:
          requests:
            cpu: "$_opt_cpu"
            memory: "$_opt_memory"
          limits:
            cpu: "$_opt_cpu_limit"
            memory: "$_opt_memory_limit"
        $(if [ -n "$_deployment_ports" ]; then echo "$_deployment_ports"; fi)
$(if [ -n "$_env_from" ] && [ "$_env_from" != "envFrom:" ]; then echo "$_env_from"| awk '{print "        " $0}'; fi)
$(if [ -n "$_volume_mounts" ] && [ "$_volume_mounts" != "envFrom:" ]; then echo "$_volume_mounts"| awk '{print "        " $0}'; fi)
$(if [ -n "$_lifecycle_policy" ]; then echo "$_lifecycle_policy" | awk '{print "        " $0}'; fi)
$(if [ -n "$_pod_anti_affinity" ]; then echo "$_pod_anti_affinity" | awk '{print "      " $0}'; fi)
$(if [ -n "$_volumes" ]; then echo "$_volumes" | awk '{print "      " $0}'; fi)
EOF
}

generate_configmap() {
    if [ -n "$_opt_configmap_template_file" ]; then
        return
    fi
    echo "Generating Configmap"
    __env_kvp=""
    _underscore_env_name="${_opt_env//-/_}"
    for key in "${!configmap_data[@]}"; do
        __value=""
        __default_value="${configmap_data[$key]}"
        __env_key="${_underscore_env_name^^}_${key}"
        __fallback_key="${key}"
        if [[ -v "$__env_key" ]]; then
            __value="${!__env_key}"
        elif [[ -v "$__fallback_key" ]]; then
            __value="${!__fallback_key}"
        fi
        # If __value is empty, use the default value
        if [ -z "$__value" ]; then
            __value="${__default_value}"
        fi
        if [ -z "$__value" ]; then
            if [ "$_opt_skip_empty" = true ]; then
                # Value is not defined, skip
                continue
            fi
        fi
        __env_kvp="${__env_kvp}  $key: \"$__value\"
"
    done
    if [ ! -n "$__env_kvp" ]; then
        echo "Configmap data is empty, skipping"
        return
    fi
    cat <<EOF >$_opt_output/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: $_opt_env-$_opt_app_name
  namespace: $_opt_env
  labels:
    app: $_opt_app_name
    env: $_opt_env
data:
$__env_kvp
EOF
    _gen_configmap=true
}

generate_configmap_template() {
    if [ -z "$_opt_configmap_template_file" ]; then
        return
    fi
    echo "Generating Configmap from template"
    cp $_opt_configmap_template_file ./config.tmp.json

    _underscore_env_name="${_opt_env//-/_}"
    for key in "${!configmap_data[@]}"; do
        __value=""
        __default_value="${configmap_data[$key]}"
        __env_key="${_underscore_env_name^^}_${key}"
        __fallback_key="${key}"
        if [[ -v "$__env_key" ]]; then
            __value="${!__env_key}"
        elif [[ -v "$__fallback_key" ]]; then
            __value="${!__fallback_key}"
        fi
        # If __value is empty, use the default value
        if [ -z "$__value" ]; then
            __value="${__default_value}"
        fi
        if [ -z "$__value" ]; then
            if [ "$_opt_skip_empty" = true ]; then
                # Value is not defined, skip
                continue
            fi
        fi
        
        sed -i "s#<${key,,}>#$__value#g" ./config.tmp.json
    done
    json_body=$(cat ./config.tmp.json)

    rm ./config.tmp.json
    cat <<EOF >$_opt_output/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: $_opt_env-$_opt_app_name
  namespace: $_opt_env
  labels:
    app: $_opt_app_name
    env: $_opt_env
data:
  $_opt_configmap_map_path : |
$(echo "$json_body" | sed 's/^/    /')
EOF
    _gen_configmap=true

}

generate_secrets() {
    __env_kvp=""
    _underscore_env_name="${_opt_env//-/_}"
    for key in "${!secret_data[@]}"; do
        __value=""
        __default_value="${secret_data[$key]}"
        __env_key="${_underscore_env_name^^}_${key}"
        __fallback_key="${key}"
        if [[ -v "$__env_key" ]]; then
            __value="${!__env_key}"
        elif [[ -v "$__fallback_key" ]]; then
            __value="${!__fallback_key}"
        fi
        # If __value is empty, use the default value
        if [ -z "$__value" ]; then
            __value="${__default_value}"
        fi
        if [ -z "$__value" ]; then
            if [ "$_opt_skip_empty" = true ]; then
                # Value is not defined, skip
                continue
            fi
        fi
        
        # Base64 encode the value (no newline)
        __b64_value=$(printf "%s" "$__value" | base64 | tr -d '\n')
        __env_kvp="${__env_kvp}  $key: \"$__b64_value\"
"
    done
    if [ ! -n "$__env_kvp" ]; then
        echo "Secrets data is empty, skipping"
        return
    fi
    echo "Generating Secrets"
    cat <<EOF >$_opt_output/secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: $_opt_env-$_opt_app_name
  namespace: $_opt_env
  labels:
    app: $_opt_app_name
    env: $_opt_env
data:
$__env_kvp
EOF
    _gen_secrets=true
}

generate_service() {
    echo "Generating Service"
    if [ ${#_opt_service_ports[@]} -ne 0 ]; then
        __service_ports=""
        for key in "${!_opt_service_ports[@]}"; do
            _port="${_opt_service_ports[$key]}"
            __service_ports+="
    - name: $key
      port: $_port
      targetPort: $_port
      protocol: TCP"
        done
    fi
    cat <<EOF >$_opt_output/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: $_opt_env-$_opt_app_name
  namespace: $_opt_env
  labels:
    app: $_opt_app_name
    env: $_opt_env
spec:
  type: $_opt_service_type
  selector:
    app: $_opt_app_name
    env: $_opt_env
  $(if [ -n "$__service_ports" ]; then echo "ports: $__service_ports"; fi)
EOF
}

generate_hpa() {
    echo "Generating HPA"
    cat <<EOF >$_opt_output/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: $_opt_env-$_opt_app_name
  namespace: $_opt_env
  labels:
    app: $_opt_app_name
    env: $_opt_env
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $_opt_env-$_opt_app_name
  minReplicas: $_opt_replicas
  maxReplicas: $_opt_max_replicas
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: $_opt_hpa_utilization_threshold
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: $_opt_hpa_utilization_threshold
EOF
}

_gen_configmap=false
_gen_secrets=false
generate_configmap
generate_configmap_template
generate_secrets

if [ "$_opt_gen_deployment" = true ]; then
    generate_deployment
fi

if [ "$_opt_gen_service" = true ]; then
    generate_service
fi

if [ "$_opt_max_replicas" -gt "$_opt_replicas" ]; then
    generate_hpa
fi
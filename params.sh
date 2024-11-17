#!/bin/bash
set -eo pipefail

if [ "$1" == "--help" ]; then
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --env                 Environment (required)"
    echo "  --app-name            Application name (required)"
    echo "  --image               Container image (required)"
    echo "  --cpu                 CPU request (default: 100m)"
    echo "  --memory              Memory request (default: 512Mi)"
    echo "  --cpu-limit           CPU limit (default: same as request)"
    echo "  --memory-limit        Memory limit (default: same as request)"
    echo "  --replicas            Number of replicas (default: 1)"
    echo "  --max-replicas        Max replicas for scaling (default: 1)"
    echo "  --ports               Comma-separated list of container ports"
    echo "  --configmap-data      Comma-separated list of key=value pairs for ConfigMap"
    echo "                        (e.g., --configmap-data key1=value1,key2=value2)"
    echo "  --secret-data         Comma-separated list of key=value pairs for Secret"
    echo "                        (e.g., --secret-data secret1=value1,secret2=value2)"
    echo "  --generate-deployment Generate deployment manifest"
    echo "  --generate-hpa        Generate horizontal pod autoscaler manifest"
    echo "  --skip-empty          Skip empty ConfigMap/Secret entries (default: false)"
    echo "  --out                 Output directory (default: ./dist)"
    exit 0
fi
_opt_cpu="100m"
_opt_memory="512Mi"
_opt_cpu_limit=""
_opt_memory_limit=""
_opt_output="$(pwd)/dist"
_opt_gen_deployment=false
_opt_gen_service=false
_opt_gen_hap=false
_opt_skip_empty=false
_opt_replicas=1
_opt_max_replicas=1
_opt_ports=""
declare -A configmap_data
declare -a secret_data
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
            shift; _opt_ports=$1;;
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
        --generate-deployment )
            _opt_gen_deployment=true;;
        --generate-service )
            _opt_gen_service=true;;
        --generate-hap )
            _opt_gen_hap=true;;
        --skip-empty )
            _opt_skip_empty=true;;
        --out )
            shift; _opt_output=$1;;
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
if [ -n "$_opt_ports" ]; then
    IFS=',' read -ra port_array <<< "$_opt_ports"
    for port in "${port_array[@]}"; do
        if ! [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]; then
            echo "Error: Invalid port: $port. Ports must be integers between 1 and 65535."
            exit 1
        fi
    done
fi

# Validate the output directory path
if [ ! -d "$_opt_output" ]; then
    echo "Error: Output directory '$_opt_output' does not exist."
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
################## End Validation ################

echo "Environment: $_opt_env"
echo "Application: $_opt_app_name"

generate_deployment() {
    # if ports is not empty string then build ports string for deployment
    if [ -n "$_opt_ports" ]; then
        _deployment_ports="
        ports:"
        IFS=',' read -ra port_array <<< "$_opt_ports"
        for port in "${port_array[@]}"; do
            _deployment_ports+="
          - containerPort: $port"
        done
    else
        _deployment_ports=""
    fi
    # Check if configmap.yaml exists and add the environment variables if it does
    _configmap_env_vars=""
    if [ "$_gen_configmap" == true ]; then
        _configmap_env_vars="
        envFrom:
        - configMapRef:
            name: $_opt_env-$_opt_app_name"
    fi

    # Check if secrets.yaml exists and add the environment variables if it does
    _secret_env_vars=""
    if [ "$_gen_secrets" == true ]; then
        _secret_env_vars="
        envFrom:
        - secretRef:
            name: $_opt_env-$_opt_app_name"
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
      containers:
      - name: $_opt_app_name
        image: $_opt_image
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: "$_opt_cpu"
            memory: "$_opt_memory"
          limits:
            cpu: "$_opt_cpu_limit"
            memory: "$_opt_memory_limit"
        $(if [ -n "$_deployment_ports" ]; then echo "$_deployment_ports"; fi)
        $(if [ -n "$_configmap_env_vars" ]; then echo "$_configmap_env_vars"; fi)
        $(if [ -n "$_secret_env_vars" ]; then echo "$_secret_env_vars"; fi)
EOF
}

generate_configmap() {
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
        __env_kvp="${__env_kvp}  $key: \"$__value\"
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

_gen_configmap=false
_gen_secrets=false
generate_configmap
generate_secrets

if [ "$_opt_gen_deployment" = true ]; then
    generate_deployment
fi

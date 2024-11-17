#!/bin/bash
set -eo pipefail

if [ "$1" == "--help" ]; then
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --env               Environment (required)"
    echo "  --app-name          Application name (required)"
    echo "  --image             Container image (required)"
    echo "  --cpu               CPU request (default: 100m)"
    echo "  --memory            Memory request (default: 512Mi)"
    echo "  --cpu-limit         CPU limit (default: same as request)"
    echo "  --memory-limit      Memory limit (default: same as request)"
    echo "  --replicas          Number of replicas (default: 1)"
    echo "  --max-replicas      Max replicas for scaling (default: 1)"
    echo "  --ports             Comma-separated list of container ports"
    echo "  --generate-deployment  Generate deployment manifest"
    echo "  --generate-service     Generate service manifest"
    echo "  --generate-configmap   Generate configmap manifest"
    echo "  --out               Output directory (default: ./dist)"
    exit 0
fi
_opt_cpu="100m"
_opt_memory="512Mi"
_opt_cpu_limit=""
_opt_memory_limit=""
_opt_output="$(pwd)/dist"
_opt_gen_deployment=false
_opt_gen_configmap=false
_opt_gen_service=false
_opt_gen_hap=false
_opt_replicas=1
_opt_max_replicas=1
_opt_ports=""
declare -A configmap_data
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
        --generate-deployment )
            _opt_gen_deployment=true;;
        --generate-configmap )
            _opt_gen_configmap=true;;
        --generate-service )
            _opt_gen_service=true;;
        --generate-hap )
            _opt_gen_hap=true;;
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
if [ -z "$_opt_env" ]; then
    echo "--env is required"
    exit 1
fi
if [ -z "$_opt_app_name" ]; then
    echo "--app-name is required"
    exit 1
fi
if [ -z "$_opt_image" ]; then
    echo "--image is required"
    exit 1
fi
if [ -z "$_opt_cpu" ]; then
    echo "--cpu is required"
    exit 1
fi
if [ -z "$_opt_memory" ]; then
    echo "--memory is required"
    exit 1
fi
if [ -z "$_opt_replicas" ]; then
    echo "--replicas is required"
    exit 1
fi
if ! [[ "$_opt_replicas" =~ ^[0-9]+$ ]]; then
    echo "--replicas must be a positive integer"
    exit 1
fi
if [ -z "$_opt_max_replicas" ]; then
    echo "--max-replicas is required"
    exit 1
fi
if ! [[ "$_opt_max_replicas" =~ ^[0-9]+$ ]]; then
    echo "--max-replicas must be a positive integer"
    exit 1
fi
if [ -n "$_opt_ports" ]; then
    IFS=',' read -ra port_array <<< "$_opt_ports"
    for port in "${port_array[@]}"; do
        if ! [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]; then
            echo "Invalid port: $port. Ports must be integers between 1 and 65535."
            exit 1
        fi
    done
fi
################## End Validation ################

echo "Environment: $_opt_env"
echo "Application: $_opt_app_name"
echo "Cpu: $_opt_cpu"
echo "Memory: $_opt_memory"
echo "Replicas: $_opt_replicas"
echo "Max Replicas: $_opt_max_replicas"
echo "Image: $_opt_image"
echo "Ports: $_opt_ports"
echo "Output: $_opt_output"
echo "Generate Deployment: $_opt_gen_deployment"
echo "Generate Configmap: $_opt_gen_configmap"
echo "Generate Service: $_opt_gen_service"

mkdir -p $_opt_output

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
    echo "Generating Deployment"
    cat <<EOF >$_opt_output/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $_opt_app_name
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
            cpu: $_opt_cpu
            memory: $_opt_memory
          limits:
            cpu: $_opt_cpu_limit
            memory: $_opt_memory_limit
        $(if [ -n "$_deployment_ports" ]; then echo "$_deployment_ports"; fi)
EOF
}

generate_configmap() {
    echo "Generating Configmap"
    cat <<EOF >$_opt_output/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: $_opt_app_name
  namespace: $_opt_env
  labels:
    app: $_opt_app_name
    env: $_opt_env
data:
EOF
    for key in "${!configmap_data[@]}"; do
        value="${configmap_data[$key]}"

        echo "  $key: \"$value\"" >>$_opt_output/configmap.yaml
    done
}

if [ "$_opt_gen_deployment" = true ]; then
    generate_deployment
fi

if [ "$_opt_gen_configmap" = true ]; then
    generate_configmap
fi
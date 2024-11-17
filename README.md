# Kubernetes Deployment and Service Generator Script

This script helps you generate Kubernetes Deployment and Service manifests for an application. It allows you to configure the number of replicas, CPU and memory resource requests and limits, environment variables via ConfigMaps and Secrets, and Kubernetes service configurations.

## Features

- Generate Kubernetes Deployment and Service manifests
- Specify CPU, memory, and resource limits
- Define ConfigMap and Secret data for environment variables
- Configure Kubernetes service type and ports
- Generate Horizontal Pod Autoscaler (HPA) manifest
- Output manifests to a specified directory

## Requirements

- `bash`
- `kubectl` (optional, if you want to deploy manually after generation)

## Usage

Run the script with the required flags to generate your Kubernetes manifests.

```bash
./gen.sh [options]
```
## Examples
### Generate Deployment and Service Manifests
```bash
./gen.sh \
--env prod \
--app-name my-app \
--image my-app-image:v1 \
--cpu 200m \
--memory 1Gi \
--replicas 3 \
--service-type LoadBalancer \
--generate-deployment \
--generate-service \
--out ./k8s-manifests
```
This will generate the Kubernetes Deployment and Service manifests for my-app, using the image my-app-image:v1 with 3 replicas and a LoadBalancer service.

### Generate Deployment Only
```bash
./gen.sh \
--env prod \
--app-name my-app \
--image my-app-image:v1 \
--generate-deployment
```
This will only generate the Kubernetes Deployment manifest.
### Generate Deployment with ConfigMap and Secret Data
```bash
./gen.sh \
--env prod \
--app-name my-app \
--image my-app-image:v1 \
--configmap-data DB_HOST=localhost,DB_PORT=5432 \
--secret-data DB_PASSWORD=secret_password \
--generate-deployment
```
This will include the ConfigMap and Secret data in the Deployment manifest.
## Notes
- The script does not automatically deploy to Kubernetes. It only generates the manifests. You can deploy them using kubectl after generation.
- If you don't specify some values, default values will be used (e.g., 1 replica, 100m CPU request, etc.).
- For HPA to work, ensure you have a valid CPU and memory threshold and that the metrics-server is set up in your cluster.

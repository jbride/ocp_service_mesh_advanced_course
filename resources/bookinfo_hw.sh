#!/bin/bash

NAMESPACE=bookinfo

# Responsible for injecting the istio annotation that opts in a Deploy for auto injection of the envoy sidecar
function injectSidecarAndResume() {

  echo -en "\n\nInjecting istio sidecar annotation into Deploy= $DC_NAME ;  APP_BASE= $APP_BASE ;    VERSION= $VERSION\n"

  # 1)  Add istio inject annotion into pod.spec.template
  oc patch deploy $DC_NAME --type='json' -p \
     "[{\"op\": \"add\", \"path\": \"/spec/template/metadata\", \"value\": {\"annotations\":{\"sidecar.istio.io/inject\": \"true\"}, \"labels\":{\"app\":\"$APP_BASE\",\"version\":\"$VERSION\"}}}]" -n $NAMESPACE

  # 2)  Loop until envoy enabled pod starts up
  replicas=1
  readyReplicas=0 
  counter=1
  while (( $replicas != $readyReplicas && $counter != 20 ))
  do
    sleep 10 
    oc get deploy $DC_NAME -o json -n $NAMESPACE > /tmp/$DC_NAME.json
    replicas=$(cat /tmp/$DC_NAME.json | jq .status.replicas)
    readyReplicas=$(cat /tmp/$DC_NAME.json | jq .status.readyReplicas)
    echo -en "\n$counter    $DC_NAME    $replicas   $readyReplicas\n"
    let counter=counter+1
  done
}

function addMTLSPolicy() {

  echo -en "\n\nAdd STRICT policy to $NAMESPACE\n"
  echo "
apiVersion: authentication.istio.io/v1alpha1
kind: Policy
metadata:
  name: default
spec:
  peers:
  - mtls:
      mode: STRICT" \
  | oc create -n $NAMESPACE -f -

}

addDestinationRules() {
    oc create -n $NAMESPACE \
              -f https://raw.githubusercontent.com/istio/istio/1.4.0/samples/bookinfo/networking/destination-rule-all-mtls.yaml
}


createMTLSkeys() {

cat <<EOF | sudo tee /tmp/cert.cfg
[ req ]
req_extensions     = req_ext
distinguished_name = req_distinguished_name
prompt             = no

[req_distinguished_name]
commonName=$NAMESPACE.apps.$SUBDOMAIN_BASE

[req_ext]
subjectAltName   = @alt_names

[alt_names]
DNS.1  = $NAMESPACE.apps.$SUBDOMAIN_BASE
DNS.2  = *.$NAMESPACE.apps.$SUBDOMAIN_BASE
EOF

openssl req -x509 -config /tmp/cert.cfg -extensions req_ext -nodes -days 730 -newkey rsa:2048 -sha256 -keyout /tmp/tls.key -out /tmp/tls.crt
oc create secret tls istio-ingressgateway-certs --cert /tmp/tls.crt --key /tmp/tls.key -n $RHSM_CONTROL_PLANE_NS
oc patch deployment istio-ingressgateway -p '{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt": "'`date -Iseconds`'"}}}}}' -n $RHSM_CONTROL_PLANE_NS
}


createMTLSGateway() {

echo "apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: $NAMESPACE-wildcard-gateway
spec:
  selector:
    istio: ingressgateway # use istio default controller
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      privateKey: /etc/istio/ingressgateway-certs/tls.key
      serverCertificate: /etc/istio/ingressgateway-certs/tls.crt
    hosts:
    - \"*.$NAMESPACE.apps.$SUBDOMAIN_BASE\"" \
  | oc create -n $NAMESPACE -f - 

echo "apiVersion: route.openshift.io/v1
kind: Route
metadata:
  annotations:
    openshift.io/host.generated: \"true\"
  name: bookinfo-productpage-gateway
spec:
  host: productpage.$NAMESPACE.apps.$SUBDOMAIN_BASE
  port:
    targetPort: https
  tls:
    insecureEdgeTerminationPolicy: Allow
    termination: edge
  to:
    kind: Service
    name: istio-ingressgateway
    weight: 100
  wildcardPolicy: None" \
  | oc create -n $RHSM_CONTROL_PLANE_NS -f - 

echo "apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: productpage-virtualservice
spec:
  hosts:
  - productpage.$NAMESPACE.apps.$SUBDOMAIN_BASE
  gateways:
  - $NAMESPACE-wildcard-gateway
  http:
  - route:
    - destination:
        port:
          number: 9080
        host: productpage.$NAMESPACE.svc.cluster.local" \
  | oc create -n $NAMESPACE -f - 

}

# Enable bookinfo deployments with Envoy auto-injection
for DC_NAME in $(oc get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}' -n $NAMESPACE ) 
do
  APP_BASE=$(echo $DC_NAME | cut -d'-' -f 1)
  VERSION=$(echo $DC_NAME | cut -d'-' -f 2)
  injectSidecarAndResume
done

addMTLSPolicy
addDestinationRules
createMTLSkeys
createMTLSGateway

docker build -t weibh/restart-in-pod -f Dockerfile .
docker push weibh/restart-in-pod
kubectl apply -f deploy.yaml
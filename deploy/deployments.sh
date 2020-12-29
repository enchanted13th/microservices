#!/bin/sh

echo "product-composite-service 애플리케이션 실행"
nohup java -jar ../microservices/product-composite-service/build/libs/*.jar > logs/product-composite-service.out 2>&1 &
PRODUCT_COMPOSITE_SERVICE_PID=$(ps ax | grep product-composite-service | grep -v grep | awk '{print $1}')
echo "product-composite-service 애플리케이션 pid: $PRODUCT_COMPOSITE_SERVICE_PID"

echo "product-service 애플리케이션 실행"
nohup java -jar ../microservices/product-service/build/libs/*.jar > logs/product-service.out 2>&1 &
PRODUCT_SERVICE_PID=$(ps ax | grep product-service | grep -v grep | awk '{print $1}')
echo "product-service 애플리케이션 pid: $PRODUCT_SERVICE_PID"

echo "recommendation-service 애플리케이션 실행"
nohup java -jar ../microservices/recommendation-service/build/libs/*.jar > logs/recommendation-service.out 2>&1 &
RECOMMENDATION_SERVICE_PID=$(ps ax | grep recommendation-service | grep -v grep | awk '{print $1}')
echo "recommendation-service 애플리케이션 pid: $RECOMMENDATION_SERVICE_PID"

echo "review-service 애플리케이션 실행"
nohup java -jar ../microservices/review-service/build/libs/*.jar > logs/review-service.out 2>&1 &
REVIEW_SERVICE_PID=$(ps ax | grep review-service | grep -v grep | awk '{print $1}')
echo "review-service 애플리케이션 pid: $REVIEW_SERVICE_PID"

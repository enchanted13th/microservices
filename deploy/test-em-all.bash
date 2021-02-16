#!/usr/bin/env bash

: ${HOST=localhost}
: ${PORT=8443}

: ${PROD_ID_REVS_RECS=2}
: ${PROD_ID_NOT_FOUND=13}
: ${PROD_ID_NO_RECS=114}
: ${PROD_ID_NO_REVS=214}

function assertCurl() {
  local expectedHttpCode=$1
  local curlCmd="$2 -w \"%{http_code}\""
  local result=$(eval $curlCmd)
  local httpCode="${result:(-3)}"

  RESPONSE='' && (( ${#result} > 3 )) && RESPONSE="${result%???}"

  if [ "$httpCode" = "$expectedHttpCode" ]
  then
    if [ "$httpCode" = "200" ]
    then
      echo "Test OK (HTTP Code: $httpCode)"
    else
      echo "Test OK (HTTP Code: $httpCode, $RESPONSE)"
    fi
    return 0;
  else
    echo "Test FAILED, EXPECTED HTTP Code: $expectedHttpCode, GOT: $httpCode, WILL ABORT!"
    echo "- Failing command: $curlCmd"
    echo "- Response Body: $RESPONSE"
    return 1
  fi
}

function assertEqual() {
  local expected=$1
  local actual=$2

  if [ "$actual" = "$expected" ]
  then
    echo "Test OK (actual value: $actual)"
    return 0
  else
    echo "Test FAILED, EXPECTED VALUE: $expected, ACTUAL VALUE: $actual, WILL ABORT"
    return 1
  fi
}

function testUrl() {
  url=$@
  if $url -ks -f -o /dev/null
  then
    return 0
  else
    return 1
  fi;
}

function waitForService() {
  url=$@
  echo -n "Wait for: $url... "
  n=0
  until testUrl $url
  do
    n=$((n + 1))
    if [[ $n == 100 ]]
    then
      echo " Give up"
      exit 1
    else
      sleep 3
      echo -n ", retry #$n "
    fi
  done
  echo "DONE, continues..."
}

function testCompositeCreated() {
    if ! assertCurl 200 "curl $AUTH -k https://$HOST:$PORT/product-composite/$PROD_ID_REVS_RECS -s"
    then
      echo -n "FAIL"
      return 1
    fi

    set +e
    assertEqual "$PROD_ID_REVS_RECS" $(echo $RESPONSE | jq .productId)
    if [ "$?" -eq "1" ] ; then return 1; fi

    assertEqual 3 $(echo $RESPONSE | jq ".recommendations | length")
    if [ "$?" -eq "1" ] ; then return 1; fi

    assertEqual 3 $(echo $RESPONSE | jq ".reviews | length")
    if [ "$?" -eq "1" ] ; then return 1; fi

    set -e
}

function waitForMessageProcessing() {
    echo "Wait for messages to be processed... "

    sleep 1

    n=0
    until testCompositeCreated
    do
      n=$((n + 1))
      if [[ $n == 40 ]]
      then
        echo " Give up"
        exit 1
      else
        sleep 3
        echo -n ", retry #$n "
      fi
    done
    echo "All messages are now processed!"
}

function recreateComposite() {
  local productId=$1
  local composite=$2

  assertCurl 200 "curl $AUTH -X DELETE -k https://$HOST:$PORT/product-composite/${productId} -s"
  curl -X POST -k https://$HOST:$PORT/product-composite -H "Content-Type: application/json" -H "Authorization: Bearer $ACCESS_TOKEN" --data "$composite"
}

function setupTestdata() {

  body="{\"productId\":$PROD_ID_NO_RECS"
  body+=\
',"name":"product name A","weight":100, "reviews":[
    {"reviewId":1,"author":"author 1","subject":"subject 1","content":"content 1"},
    {"reviewId":2,"author":"author 2","subject":"subject 2","content":"content 2"},
    {"reviewId":3,"author":"author 3","subject":"subject 3","content":"content 3"}
]}'
  recreateComposite "$PROD_ID_NO_RECS" "$body"

  body="{\"productId\":$PROD_ID_NO_REVS"
  body+=\
',"name":"product name B","weight":200, "recommendations":[
    {"recommendationId":1,"author":"author 1","rate":1,"content":"content 1"},
    {"recommendationId":2,"author":"author 2","rate":2,"content":"content 2"},
    {"recommendationId":3,"author":"author 3","rate":3,"content":"content 3"}
]}'
  recreateComposite "$PROD_ID_NO_REVS" "$body"

  body="{\"productId\":$PROD_ID_REVS_RECS"
  body+=\
',"name":"product name C","weight":300, "recommendations":[
      {"recommendationId":1,"author":"author 1","rate":1,"content":"content 1"},
      {"recommendationId":2,"author":"author 2","rate":2,"content":"content 2"},
      {"recommendationId":3,"author":"author 3","rate":3,"content":"content 3"}
  ], "reviews":[
      {"reviewId":1,"author":"author 1","subject":"subject 1","content":"content 1"},
      {"reviewId":2,"author":"author 2","subject":"subject 2","content":"content 2"},
      {"reviewId":3,"author":"author 3","subject":"subject 3","content":"content 3"}
  ]}'
  recreateComposite 1 "$body"

}

function testCircuitBreaker() {

  echo "Start Circuit Breaker tests!"

  EXEC="docker run --rm -it --network=my-network alpine"

  # Endpoint to verify that the circuit breaker is closed
  assertEqual "CLOSED" "$($EXEC wget product-composite:8080/actuator/health -qO - | jq -r .components.circuitBreakers.details.product.details.state)"

  # Open the circuit breaker
  assertCurl 500 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_REVS_RECS?delay=3 $AUTH -s"
  message=$(echo $RESPONSE | jq -r .message)
  assertEqual "Did not observe any item or terminal signal within 2000ms" "${message:0:57}"

  # Verify that the circuit breaker now is open by running the slow call again
  assertCurl 200 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_REVS_RECS?delay=3 $AUTH -s"
  assertEqual "Fallback product2" "$(echo "$RESPONSE" | jq -r .name)"

  # Verify that the circuit breaker is open by running a normal call
  assertCurl 200 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_REVS_RECS $AUTH -s"
  assertEqual "Fallback product2" "$(echo "$RESPONSE" | jq -r .name)"

  # Verify that a 404 error is returned for a non existing productId ($PROD_ID_NOT_FOUND)
  assertCurl 404 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_NOT_FOUND $AUTH -s"
  assertEqual "Product Id: $PROD_ID_NOT_FOUND not found in fallback cache!" "$(echo $RESPONSE | jq -r .message)"

  # Wait for the circuit breaker to transition to half open state
  echo "Will sleep for 5 sec waiting for the CB to go Half Open..."
  sleep 5

  # Verify that the circuit breaker is in half open state
  assertEqual "HALF_OPEN" "$($EXEC wget product-composite:8080/actuator/health -qO - | jq -r .components.circuitBreakers.details.product.details.state)"

  # Close the circuit breaker by running three normal calls in a row
    for ((n=0; n<3; n++))
    do
        assertCurl 200 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_REVS_RECS $AUTH -s"
        assertEqual "product name C" "$(echo "$RESPONSE" | jq -r .name)"
    done

  # Verify that the circuit breaker is in closed state again
  assertEqual "CLOSED" "$($EXEC wget product-composite:8080/actuator/health -qO - | jq -r .components.circuitBreakers.details.product.details.state)"

  # Verify that the expected state transitions happened in the circuit breaker
  assertEqual "CLOSED_TO_OPEN" "$($EXEC wget product-composite:8080/actuator/circuitbreakerevents/product/STATE_TRANSITION -qO - | jq -r .circuitBreakerEvents[-3].stateTransition)"
  assertEqual "OPEN_TO_HALF_OPEN" "$($EXEC wget product-composite:8080/actuator/circuitbreakerevents/product/STATE_TRANSITION -qO - | jq -r .circuitBreakerEvents[-2].stateTransition)"
  assertEqual "HALF_OPEN_TO_CLOSED" "$($EXEC wget product-composite:8080/actuator/circuitbreakerevents/product/STATE_TRANSITION -qO - | jq -r .circuitBreakerEvents[-1].stateTransition)"
}

set -e

echo "Start Tests:" `date`

echo "HOST=${HOST}"
echo "PORT=${PORT}"

if [[ $@ == *"start"* ]]
then
  echo "Restarting the test environment..."
  echo "$ docker-compose down --remove-orphans"
  docker-compose down --remove-orphans
  echo "$ docker-compose up -d"
  docker-compose up -d
fi

waitForService curl -k https://$HOST:$PORT/actuator/health

ACCESS_TOKEN=$(curl -k https://writer:secret@$HOST:$PORT/oauth/token -d grant_type=password -d username=magnus -d password=password -s | jq .access_token -r)
AUTH="-H \"Authorization: Bearer $ACCESS_TOKEN\""

setupTestdata

waitForMessageProcessing

# Verify that a normal request works
assertCurl 200 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_REVS_RECS $AUTH -s"
assertEqual "$PROD_ID_REVS_RECS" $(echo $RESPONSE | jq .productId)
assertEqual 3 $(echo $RESPONSE | jq ".recommendations | length")
assertEqual 3 $(echo $RESPONSE | jq ".reviews | length")

# Verify that a 404 error
assertCurl 404 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_NOT_FOUND $AUTH -s"

# Verify that no recommendations
assertCurl 200 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_NO_REVS $AUTH -s"
assertEqual $PROD_ID_NO_REVS $(echo $RESPONSE | jq .productId)
assertEqual 3 $(echo $RESPONSE | jq ".recommendations | length")
assertEqual 0 $(echo $RESPONSE | jq ".reviews | length")

# Verify that no reviews
assertCurl 200 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_NO_REVS $AUTH -s"
assertEqual $PROD_ID_NO_REVS $(echo $RESPONSE | jq .productId)
assertEqual 3 $(echo $RESPONSE | jq ".recommendations | length")
assertEqual 0 $(echo $RESPONSE | jq ".reviews | length")

# Verify that a 422 error
assertCurl 422 "curl -k https://$HOST:$PORT/product-composite/-1 $AUTH -s"
assertEqual "\"Invalid productId: -1\"" "$(echo $RESPONSE | jq .message)"

# Verify that a 400 error
assertCurl 400 "curl -k https://$HOST:$PORT/product-composite/invalidProductId $AUTH -s"
assertEqual "\"Type mismatch.\"" "$(echo $RESPONSE | jq .message)"

# Verify that a request without access token
assertCurl 401 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_REVS_RECS -s"

# Verify that the reader
READER_ACCESS_TOKEN=$(curl -k https://reader:secret@$HOST:$PORT/oauth/token -d grant_type=password -d username=magnus -d password=password -s | jq .access_token -r)
READER_AUTH="-H \"Authorization: Bearer $READER_ACCESS_TOKEN\""

assertCurl 200 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_REVS_RECS $READER_AUTH -s"
assertCurl 403 "curl -k https://$HOST:$PORT/product-composite/$PROD_ID_REVS_RECS $READER_AUTH -X DELETE -s"

testCircuitBreaker

echo "End, all tests OK:" `date`

if [[ $@ == *"stop"* ]]
then
  echo "We are done, stopping the test environment..."
  echo "$ docker-compose down --remove-orphans"
  docker-compose down --remove-orphans
fi
#!/bin/bash
echo "Checking Firebase Storage setup..."
firebase projects:list | grep soramoyou-ios
echo ""
echo "Attempting to deploy storage rules..."
firebase deploy --only storage

/*
Copyright 2024 The Karmada Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package propagationpolicy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
	mcsv1alpha1 "sigs.k8s.io/mcs-api/pkg/apis/v1alpha1"

	policyv1alpha1 "github.com/karmada-io/karmada/pkg/apis/policy/v1alpha1"
	"github.com/karmada-io/karmada/pkg/util"
	"github.com/karmada-io/karmada/pkg/util/helper"
	"github.com/karmada-io/karmada/pkg/util/validation"
)

type fakeMutationDecoder struct {
	err error
	obj runtime.Object
}

// Decode mocks the Decode method of admission.Decoder.
func (f *fakeMutationDecoder) Decode(_ admission.Request, obj runtime.Object) error {
	if f.err != nil {
		return f.err
	}
	if f.obj != nil {
		reflect.ValueOf(obj).Elem().Set(reflect.ValueOf(f.obj).Elem())
	}
	return nil
}

// DecodeRaw mocks the DecodeRaw method of admission.Decoder.
func (f *fakeMutationDecoder) DecodeRaw(_ runtime.RawExtension, obj runtime.Object) error {
	if f.err != nil {
		return f.err
	}
	if f.obj != nil {
		reflect.ValueOf(obj).Elem().Set(reflect.ValueOf(f.obj).Elem())
	}
	return nil
}

func TestMutatingAdmission_Handle(t *testing.T) {
	tests := []struct {
		name    string
		decoder admission.Decoder
		req     admission.Request
		want    admission.Response
	}{
		{
			name: "Handle_DecodeError_DeniesAdmission",
			decoder: &fakeValidationDecoder{
				err: errors.New("decode error"),
			},
			req:  admission.Request{},
			want: admission.Errored(http.StatusBadRequest, errors.New("decode error")),
		},
		{
			name: "Handle_TooLongPolicyName_DeniesAdmission",
			decoder: &fakeMutationDecoder{
				obj: &policyv1alpha1.PropagationPolicy{
					ObjectMeta: metav1.ObjectMeta{
						Name: strings.Repeat("a", validation.LabelValueMaxLength+1),
					},
					Spec: policyv1alpha1.PropagationSpec{},
				},
			},
			req: admission.Request{},
			want: admission.Errored(
				http.StatusBadRequest,
				fmt.Errorf("PropagationPolicy's name should be no more than %d characters", validation.LabelValueMaxLength),
			),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v := NewMutatingHandler(300, 300, tt.decoder)
			got := v.Handle(context.Background(), tt.req)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("Handle() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestMutatingAdmission_Handle_FullCoverage(t *testing.T) {
	// Define the policy name and namespace to be used in the test.
	policyName := "test-policy"
	namespace := "test-namespace"

	// Define default toleration seconds for the test.
	var notReadyTolerationSeconds int64 = 300
	var unreachableTolerationSeconds int64 = 300

	// Mock a request with a specific namespace.
	req := admission.Request{
		AdmissionRequest: admissionv1.AdmissionRequest{
			Namespace: namespace,
			Operation: admissionv1.Create,
		},
	}

	// Create the initial policy with default values for testing.
	policy := &policyv1alpha1.PropagationPolicy{
		ObjectMeta: metav1.ObjectMeta{
			Name: policyName,
		},
		Spec: policyv1alpha1.PropagationSpec{
			Placement: policyv1alpha1.Placement{
				SpreadConstraints: []policyv1alpha1.SpreadConstraint{
					{SpreadByLabel: "", SpreadByField: "", MinGroups: 0},
				},
				ReplicaScheduling: &policyv1alpha1.ReplicaSchedulingStrategy{
					ReplicaSchedulingType: policyv1alpha1.ReplicaSchedulingTypeDivided,
				},
			},
			PropagateDeps: false,
			ResourceSelectors: []policyv1alpha1.ResourceSelector{
				{
					Namespace:  "",
					Kind:       util.ServiceImportKind,
					APIVersion: mcsv1alpha1.GroupVersion.String(),
				},
				{Namespace: ""},
			},
			Failover: &policyv1alpha1.FailoverBehavior{
				Application: &policyv1alpha1.ApplicationFailoverBehavior{
					PurgeMode:          policyv1alpha1.Graciously,
					GracePeriodSeconds: nil,
				},
			},
		},
	}

	// Define the expected policy after mutations.
	wantPolicy := &policyv1alpha1.PropagationPolicy{
		ObjectMeta: metav1.ObjectMeta{
			Name: policyName,
			Labels: map[string]string{
				policyv1alpha1.PropagationPolicyPermanentIDLabel: "some-unique-uuid",
			},
			Finalizers: []string{util.PropagationPolicyControllerFinalizer},
		},
		Spec: policyv1alpha1.PropagationSpec{
			Placement: policyv1alpha1.Placement{
				SpreadConstraints: []policyv1alpha1.SpreadConstraint{
					{
						SpreadByField: policyv1alpha1.SpreadByFieldCluster,
						MinGroups:     1,
					},
				},
				ReplicaScheduling: &policyv1alpha1.ReplicaSchedulingStrategy{
					ReplicaSchedulingType:     policyv1alpha1.ReplicaSchedulingTypeDivided,
					ReplicaDivisionPreference: policyv1alpha1.ReplicaDivisionPreferenceWeighted,
				},
				ClusterTolerations: []corev1.Toleration{
					*helper.NewNotReadyToleration(notReadyTolerationSeconds),
					*helper.NewUnreachableToleration(unreachableTolerationSeconds),
				},
			},
			PropagateDeps: true,
			ResourceSelectors: []policyv1alpha1.ResourceSelector{
				{
					Namespace:  namespace,
					Kind:       util.ServiceImportKind,
					APIVersion: mcsv1alpha1.GroupVersion.String(),
				},
				{Namespace: namespace},
			},
			Failover: &policyv1alpha1.FailoverBehavior{
				Application: &policyv1alpha1.ApplicationFailoverBehavior{
					PurgeMode:          policyv1alpha1.Graciously,
					GracePeriodSeconds: ptr.To[int32](600),
				},
			},
		},
	}

	// Mock decoder that decodes the request into the policy object.
	decoder := &fakeMutationDecoder{
		obj: policy,
	}

	// Marshal the expected policy to simulate the final mutated object.
	wantBytes, err := json.Marshal(wantPolicy)
	if err != nil {
		t.Fatalf("Failed to marshal expected policy: %v", err)
	}
	req.Object.Raw = wantBytes

	// Instantiate the mutating handler.
	mutatingHandler := NewMutatingHandler(
		notReadyTolerationSeconds, unreachableTolerationSeconds, decoder,
	)

	// Call the Handle function.
	got := mutatingHandler.Handle(context.Background(), req)

	// Verify that the only patch applied is for the UUID label. If any other patches are present, it indicates that the policy was not handled as expected.
	if len(got.Patches) > 0 {
		firstPatch := got.Patches[0]
		if firstPatch.Operation != "replace" || firstPatch.Path != "/metadata/labels/propagationpolicy.karmada.io~1permanent-id" {
			t.Errorf("Handle() returned unexpected patches. Only the UUID patch was expected. Received patches: %v", got.Patches)
		}
	}

	// Check if the admission request was allowed.
	if !got.Allowed {
		t.Errorf("Handle() got.Allowed = false, want true")
	}
}

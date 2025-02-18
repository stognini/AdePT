// SPDX-FileCopyrightText: 2021 CERN
// SPDX-License-Identifier: Apache-2.0

#include "example10.cuh"

#include <fieldPropagatorConstBz.h>

#include <CopCore/PhysicalConstants.h>

#define NOMSC
#define NOFLUCTUATION

#include <G4HepEmElectronManager.hh>
#include <G4HepEmElectronTrack.hh>
#include <G4HepEmElectronInteractionBrem.hh>
#include <G4HepEmElectronInteractionIoni.hh>
#include <G4HepEmPositronInteractionAnnihilation.hh>
// Pull in implementation.
#include <G4HepEmRunUtils.icc>
#include <G4HepEmInteractionUtils.icc>
#include <G4HepEmElectronManager.icc>
#include <G4HepEmElectronInteractionBrem.icc>
#include <G4HepEmElectronInteractionIoni.icc>
#include <G4HepEmPositronInteractionAnnihilation.icc>

// Compute the physics and geometry step limit, transport the electrons while
// applying the continuous effects and maybe a discrete process that could
// generate secondaries.
template <bool IsElectron>
static __device__ __forceinline__ void TransportElectrons(Track *electrons, const adept::MParray *active,
                                                          Secondaries &secondaries, adept::MParray *activeQueue,
                                                          adept::MParray *relocateQueue, GlobalScoring *scoring,
                                                          int maxSteps)
{
  constexpr int Charge  = IsElectron ? -1 : 1;
  constexpr double Mass = copcore::units::kElectronMassC2;
  fieldPropagatorConstBz fieldPropagatorBz(BzFieldValue);

  int activeSize = active->size();
  for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < activeSize; i += blockDim.x * gridDim.x) {
    const int slot      = (*active)[i];
    Track &currentTrack = electrons[slot];

    // Init a track with the needed data to call into G4HepEm.
    G4HepEmElectronTrack elTrack;
    G4HepEmTrack *theTrack = elTrack.GetTrack();
    theTrack->SetEKin(currentTrack.energy);
    // For now, just assume a single material.
    int theMCIndex = 1;
    theTrack->SetMCIndex(theMCIndex);
    theTrack->SetCharge(Charge);

    bool alive = true;
    for (int s = 0; alive && s < maxSteps; s++) {

      // Sample the `number-of-interaction-left` and put it into the track.
      for (int ip = 0; ip < 3; ++ip) {
        double numIALeft = currentTrack.numIALeft[ip];
        if (numIALeft <= 0) {
          numIALeft                  = -std::log(currentTrack.Uniform());
          currentTrack.numIALeft[ip] = numIALeft;
        }
        theTrack->SetNumIALeft(numIALeft, ip);
      }

      // Call G4HepEm to compute the physics step limit.
      G4HepEmElectronManager::HowFar(&g4HepEmData, &g4HepEmPars, &elTrack, nullptr);

      // Get result into variables.
      double geometricalStepLengthFromPhysics = theTrack->GetGStepLength();
      // The phyiscal step length is the amount that the particle experiences
      // which might be longer than the geometrical step length due to MSC. As
      // long as we call PerformContinuous in the same kernel we don't need to
      // care, but we need to make this available when splitting the operations.
      // double physicalStepLength = elTrack.GetPStepLength();
      int winnerProcessIndex = theTrack->GetWinnerProcessIndex();
      // Leave the range and MFP inside the G4HepEmTrack. If we split kernels, we
      // also need to carry them over!

      // Check if there's a volume boundary in between.
      bool propagated = true;
      double geometryStepLength = fieldPropagatorBz.ComputeStepAndNextVolume(
          currentTrack.energy, Mass, Charge, geometricalStepLengthFromPhysics, currentTrack.pos, currentTrack.dir,
          currentTrack.currentState, currentTrack.nextState, propagated);

      theTrack->SetGStepLength(geometryStepLength);
      theTrack->SetOnBoundary(currentTrack.nextState.IsOnBoundary());

      // Apply continuous effects.
      bool stopped = G4HepEmElectronManager::PerformContinuous(&g4HepEmData, &g4HepEmPars, &elTrack, nullptr);
      // Collect the changes.
      currentTrack.energy = theTrack->GetEKin();
      atomicAdd(&scoring->energyDeposit, theTrack->GetEnergyDeposit());

      // Save the `number-of-interaction-left` in our track.
      for (int ip = 0; ip < 3; ++ip) {
        double numIALeft           = theTrack->GetNumIALeft(ip);
        currentTrack.numIALeft[ip] = numIALeft;
      }

      if (stopped) {
        if (!IsElectron) {
          // Annihilate the stopped positron into two gammas heading to opposite
          // directions (isotropic).
          Track &gamma1 = secondaries.gammas.NextTrack();
          Track &gamma2 = secondaries.gammas.NextTrack();
          atomicAdd(&scoring->secondaries, 2);

          const double cost = 2 * currentTrack.Uniform() - 1;
          const double sint = sqrt(1 - cost * cost);
          const double phi  = k2Pi * currentTrack.Uniform();
          double sinPhi, cosPhi;
          sincos(phi, &sinPhi, &cosPhi);

          gamma1.InitAsSecondary(/*parent=*/currentTrack);
          gamma1.rngState = currentTrack.rngState.Branch();
          gamma1.energy   = copcore::units::kElectronMassC2;
          gamma1.dir.Set(sint * cosPhi, sint * sinPhi, cost);

          gamma2.InitAsSecondary(/*parent=*/currentTrack);
          // Reuse the RNG state of the dying track.
          gamma2.rngState = currentTrack.rngState;
          gamma2.energy   = copcore::units::kElectronMassC2;
          gamma2.dir      = -gamma1.dir;
        }
        alive = false;
        break;
      }

      if (currentTrack.nextState.IsOnBoundary()) {
        // For now, just count that we hit something.
        atomicAdd(&scoring->hits, 1);

        // Kill the particle if it left the world.
        if (currentTrack.nextState.Top() != nullptr) {
          alive = true;
          relocateQueue->push_back(slot);

          // Move to the next boundary.
          currentTrack.SwapStates();
        } else {
          alive = false;
        }

        // Cannot continue for now: either the particles left the world, or we
        // need to relocate it to the next volume.
        break;
      } else if (!propagated) {
        // Did not yet reach the interaction point due to error in the magnetic
        // field propagation. Try again next time.
        continue;
      } else if (winnerProcessIndex < 0) {
        // No discrete process, move on.
        continue;
      }

      // Reset number of interaction left for the winner discrete process.
      // (Will be resampled in the next iteration.)
      currentTrack.numIALeft[winnerProcessIndex] = -1.0;

      // Check if a delta interaction happens instead of the real discrete process.
      if (G4HepEmElectronManager::CheckDelta(&g4HepEmData, theTrack, currentTrack.Uniform())) {
        // A delta interaction happened, move on.
        continue;
      }

      // Perform the discrete interaction.
      G4HepEmRandomEngine rnge(&currentTrack.rngState);
      // We will need one branched RNG state, prepare while threads are synchronized.
      RanluxppDouble newRNG(currentTrack.rngState.Branch());

      const double energy   = currentTrack.energy;
      const double theElCut = g4HepEmData.fTheMatCutData->fMatCutData[theMCIndex].fSecElProdCutE;

      switch (winnerProcessIndex) {
      case 0: {
        // Invoke ionization (for e-/e+):
        double deltaEkin = (IsElectron)
                               ? G4HepEmElectronInteractionIoni::SampleETransferMoller(theElCut, energy, &rnge)
                               : G4HepEmElectronInteractionIoni::SampleETransferBhabha(theElCut, energy, &rnge);

        double dirPrimary[] = {currentTrack.dir.x(), currentTrack.dir.y(), currentTrack.dir.z()};
        double dirSecondary[3];
        G4HepEmElectronInteractionIoni::SampleDirections(energy, deltaEkin, dirSecondary, dirPrimary, &rnge);

        Track &secondary = secondaries.electrons.NextTrack();
        atomicAdd(&scoring->secondaries, 1);

        secondary.InitAsSecondary(/*parent=*/currentTrack);
        secondary.rngState = newRNG;
        secondary.energy   = deltaEkin;
        secondary.dir.Set(dirSecondary[0], dirSecondary[1], dirSecondary[2]);

        currentTrack.energy = energy - deltaEkin;
        theTrack->SetEKin(currentTrack.energy);
        currentTrack.dir.Set(dirPrimary[0], dirPrimary[1], dirPrimary[2]);
        // The current track continues to live.
        alive = true;
        break;
      }
      case 1: {
        // Invoke model for Bremsstrahlung: either SB- or Rel-Brem.
        double logEnergy = std::log(energy);
        double deltaEkin = energy < g4HepEmPars.fElectronBremModelLim
                               ? G4HepEmElectronInteractionBrem::SampleETransferSB(&g4HepEmData, energy, logEnergy,
                                                                                   theMCIndex, &rnge, IsElectron)
                               : G4HepEmElectronInteractionBrem::SampleETransferRB(&g4HepEmData, energy, logEnergy,
                                                                                   theMCIndex, &rnge, IsElectron);

        double dirPrimary[] = {currentTrack.dir.x(), currentTrack.dir.y(), currentTrack.dir.z()};
        double dirSecondary[3];
        G4HepEmElectronInteractionBrem::SampleDirections(energy, deltaEkin, dirSecondary, dirPrimary, &rnge);

        Track &gamma = secondaries.gammas.NextTrack();
        atomicAdd(&scoring->secondaries, 1);

        gamma.InitAsSecondary(/*parent=*/currentTrack);
        gamma.rngState = newRNG;
        gamma.energy   = deltaEkin;
        gamma.dir.Set(dirSecondary[0], dirSecondary[1], dirSecondary[2]);

        currentTrack.energy = energy - deltaEkin;
        theTrack->SetEKin(currentTrack.energy);
        currentTrack.dir.Set(dirPrimary[0], dirPrimary[1], dirPrimary[2]);
        // The current track continues to live.
        alive = true;
        break;
      }
      case 2: {
        // Invoke annihilation (in-flight) for e+
        double dirPrimary[] = {currentTrack.dir.x(), currentTrack.dir.y(), currentTrack.dir.z()};
        double theGamma1Ekin, theGamma2Ekin;
        double theGamma1Dir[3], theGamma2Dir[3];
        G4HepEmPositronInteractionAnnihilation::SampleEnergyAndDirectionsInFlight(
            energy, dirPrimary, &theGamma1Ekin, theGamma1Dir, &theGamma2Ekin, theGamma2Dir, &rnge);

        Track &gamma1 = secondaries.gammas.NextTrack();
        Track &gamma2 = secondaries.gammas.NextTrack();
        atomicAdd(&scoring->secondaries, 2);

        gamma1.InitAsSecondary(/*parent=*/currentTrack);
        gamma1.rngState = newRNG;
        gamma1.energy   = theGamma1Ekin;
        gamma1.dir.Set(theGamma1Dir[0], theGamma1Dir[1], theGamma1Dir[2]);

        gamma2.InitAsSecondary(/*parent=*/currentTrack);
        // Reuse the RNG state of the dying track.
        gamma2.rngState = currentTrack.rngState;
        gamma2.energy   = theGamma2Ekin;
        gamma2.dir.Set(theGamma2Dir[0], theGamma2Dir[1], theGamma2Dir[2]);

        // The current track is killed.
        alive = false;
        break;
      }
      }
    }

    if (alive) {
      activeQueue->push_back(slot);
    }
  }
}

// Instantiate kernels for electrons and positrons.
__global__ void TransportElectrons(Track *electrons, const adept::MParray *active, Secondaries secondaries,
                                   adept::MParray *activeQueue, adept::MParray *relocateQueue, GlobalScoring *scoring,
                                   int maxSteps)
{
  TransportElectrons</*IsElectron*/ true>(electrons, active, secondaries, activeQueue, relocateQueue, scoring,
                                          maxSteps);
}
__global__ void TransportPositrons(Track *positrons, const adept::MParray *active, Secondaries secondaries,
                                   adept::MParray *activeQueue, adept::MParray *relocateQueue, GlobalScoring *scoring,
                                   int maxSteps)
{
  TransportElectrons</*IsElectron*/ false>(positrons, active, secondaries, activeQueue, relocateQueue, scoring,
                                           maxSteps);
}

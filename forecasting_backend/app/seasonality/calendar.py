from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from enum import Enum


BINAN_LOCATION_ID = "11111111-1111-1111-1111-111111111111"


class ClimateType(str, Enum):
    """Modified Coronas climate classification used by PAGASA."""

    TYPE_I = "type_i"


class PhilippineSeason(str, Enum):
    DRY = "dry"
    RAINY = "rainy"
    TRANSITION = "transition"


class SeasonTransition(str, Enum):
    NONE = "none"
    TO_RAINY = "to_rainy"
    TO_DRY = "to_dry"


@dataclass(frozen=True)
class LocationClimateProfile:
    location_id: str
    location_name: str
    province: str
    climate_type: ClimateType
    assignment_evidence_level: str
    source_name: str
    source_url: str
    rationale: str


@dataclass(frozen=True)
class SeasonContext:
    forecast_date: date
    location_id: str
    climate_type: ClimateType
    season: PhilippineSeason
    transition: SeasonTransition
    calendar_version: str
    source_name: str
    source_url: str
    interpretation: str

    def feature_vector(self) -> tuple[float, ...]:
        """Future-known categorical context; values are not demand multipliers."""

        return (
            float(self.season is PhilippineSeason.DRY),
            float(self.season is PhilippineSeason.RAINY),
            float(self.transition is SeasonTransition.TO_RAINY),
            float(self.transition is SeasonTransition.TO_DRY),
            float(self.climate_type is ClimateType.TYPE_I),
        )


class PhilippineSeasonResolver:
    """Resolve daily Philippine season context for configured store locations.

    PAGASA describes the national dry season as December-May and rainy season
    as June-November, while Modified Coronas Type I has pronounced dry and wet
    periods. May and November are represented explicitly as boundary months so
    a forecast horizon can cross a transition instead of receiving one label.
    This is a transparent calendar interpretation only: it applies no demand
    uplift or reduction.
    """

    CALENDAR_VERSION = "pagasa-type-i-core-seasons-v1"
    PAGASA_SOURCE_NAME = "PAGASA Climate of the Philippines"
    PAGASA_SOURCE_URL = (
        "https://www.pagasa.dost.gov.ph/information/climate-philippines"
    )
    BSWM_SOURCE_URL = (
        "https://www.bswm.da.gov.ph/wp-content/uploads/"
        "LAGUNA_SUITABILITY_ROBUSTA.pdf"
    )

    def __init__(
        self,
        profiles: tuple[LocationClimateProfile, ...] | None = None,
    ) -> None:
        configured = profiles or (
            LocationClimateProfile(
                location_id=BINAN_LOCATION_ID,
                location_name="Biñan Main Hardware",
                province="Laguna",
                climate_type=ClimateType.TYPE_I,
                assignment_evidence_level="corroborated_external_map",
                source_name=(
                    "PAGASA Modified Coronas climatology, corroborated by "
                    "DA-BSWM Laguna climate mapping"
                ),
                source_url=self.BSWM_SOURCE_URL,
                rationale=(
                    "The inspected store is in Biñan, western Laguna. The BSWM "
                    "Laguna map places western Laguna in Type I. Coordinates "
                    "should be recorded before extending this mapping to a new "
                    "location."
                ),
            ),
        )
        self._profiles = {profile.location_id: profile for profile in configured}
        if len(self._profiles) != len(configured):
            raise ValueError("location climate profiles contain a duplicate location")

    def location_profile(self, location_id: str) -> LocationClimateProfile:
        try:
            return self._profiles[location_id]
        except KeyError as error:
            raise ValueError(
                f"no verified climate profile is configured for location {location_id}"
            ) from error

    def resolve(self, location_id: str, forecast_date: date) -> SeasonContext:
        profile = self.location_profile(location_id)
        if profile.climate_type is not ClimateType.TYPE_I:
            raise ValueError(f"unsupported climate type: {profile.climate_type.value}")

        month = forecast_date.month
        if month == 5:
            season = PhilippineSeason.TRANSITION
            transition = SeasonTransition.TO_RAINY
        elif month == 11:
            season = PhilippineSeason.TRANSITION
            transition = SeasonTransition.TO_DRY
        elif month in {6, 7, 8, 9, 10}:
            season = PhilippineSeason.RAINY
            transition = SeasonTransition.NONE
        else:
            season = PhilippineSeason.DRY
            transition = SeasonTransition.NONE

        return SeasonContext(
            forecast_date=forecast_date,
            location_id=location_id,
            climate_type=profile.climate_type,
            season=season,
            transition=transition,
            calendar_version=self.CALENDAR_VERSION,
            source_name=self.PAGASA_SOURCE_NAME,
            source_url=self.PAGASA_SOURCE_URL,
            interpretation=(
                "Type I core seasons with May and November retained as explicit "
                "transition months; no numerical demand adjustment is implied."
            ),
        )

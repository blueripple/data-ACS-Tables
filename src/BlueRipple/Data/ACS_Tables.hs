{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module BlueRipple.Data.ACS_Tables
  (
    module BlueRipple.Data.ACS_Tables
  )
where

import qualified BlueRipple.Data.Types.Demographic as DT
import qualified BlueRipple.Data.Types.Geographic as GT
import qualified BlueRipple.Data.Keyed as K

import qualified Flat

import qualified Control.Foldl as FL
import Control.Lens (view, (^.))
import qualified Data.Array as Array
import qualified Data.Csv as CSV
import           Data.Csv ((.:))
import qualified Data.Map as Map
import qualified Frames                        as F
import qualified Frames.Streamly.InCore        as FI
import           Data.Discrimination            ( Grouping )
import qualified Data.Vinyl                    as V
import qualified Data.Vinyl.TypeLevel          as V
import qualified Data.Vector.Unboxed           as UVec
import           Data.Vector.Unboxed.Deriving   (derivingUnbox)

F.declareColumn "SqMiles" ''Double
F.declareColumn "SqKm" ''Double
F.declareColumn "PWLogPopPerSqMile" ''Double
F.declareColumn "PerCapitaIncome" ''Double
F.declareColumn "TotalIncome" ''Double

type LDLocationR = [GT.StateFIPS, GT.DistrictTypeC, GT.DistrictName]
type LDPrefixR = [GT.StateFIPS, GT.DistrictTypeC, GT.DistrictName, DT.TotalPopCount, DT.PWPopPerSqMile, TotalIncome, SqMiles, SqKm]
type CensusDataR = [SqMiles, TotalIncome, DT.PWPopPerSqMile]

aggCensusData :: FL.Fold (F.Record (CensusDataR V.++ '[DT.PopCount])) (F.Record (CensusDataR V.++ '[DT.PopCount]))
aggCensusData =
  let smF = FL.premap (view sqMiles) FL.sum
      tiF = FL.premap (view totalIncome) FL.sum
      pcF = FL.premap (view DT.popCount) FL.sum
      wpwdF = FL.premap (\r -> realToFrac (r ^. DT.popCount) * r ^. DT.pWPopPerSqMile) FL.sum
      safeDiv x y = if y /= 0 then x / realToFrac y else 0
      pwdF = safeDiv <$> wpwdF <*> pcF
  in (\sm ti pwd pc -> sm F.&: ti F.&: pwd F.&: pc F.&: V.RNil) <$> smF <*> tiF <*> pwdF <*> pcF

-- To avoid an orphan instance of FromField DistrictType
newtype DistrictTypeWrapper = DistrictTypeWrapper { unWrapDistrictType :: GT.DistrictType }

instance CSV.FromField DistrictTypeWrapper where
  parseField s
    | s == "Congressional" = pure $ DistrictTypeWrapper GT.Congressional
    | s == "StateLower" = pure $ DistrictTypeWrapper GT.StateLower
    | s == "StateUpper" = pure $ DistrictTypeWrapper GT.StateUpper
    | otherwise = mzero

newtype LDPrefix = LDPrefix { unLDPrefix :: F.Record LDPrefixR } deriving stock Show
toLDPrefix :: Int -> GT.DistrictType -> Text -> Int -> Double -> Double -> Double -> Double -> LDPrefix
toLDPrefix sf dt dn pop pwd inc sm sk
  = LDPrefix $ sf F.&: dt F.&: dn F.&: pop F.&: pwd F.&: (realToFrac pop * inc) F.&: sm F.&: sk F.&: V.RNil
--  where
--    f x y = if x == 0 then 0 else realToFrac x * Numeric.log y

instance CSV.FromNamedRecord LDPrefix where
  parseNamedRecord r = toLDPrefix
                       <$> r .: "StateFIPS"
                       <*> fmap unWrapDistrictType (r .: "DistrictType")
                       <*> r .: "DistrictName"
                       <*> r .: "TotalPopulation"
                       <*> r .: "pwPopPerSqMile"
                       <*> r .: "PerCapitaIncome"
                       <*> r .: "SqMiles"
                       <*> r .: "SqKm"

-- types for tables
data Age14 = A14_Under5 | A14_5To9 | A14_10To14 | A14_15To17 | A14_18To19 | A14_20To24
           | A14_25To29 | A14_30To34 | A14_35To44 | A14_45To54
           | A14_55To64 | A14_65To74 | A14_75To84 | A14_85AndOver deriving stock (Show, Enum, Bounded, Eq, Ord, Array.Ix, Generic)

instance Flat.Flat Age14
instance Grouping Age14
instance K.FiniteSet Age14

derivingUnbox "Age14"
  [t|Age14 -> Word8|]
  [|toEnum . fromEnum|]
  [|toEnum . fromEnum|]
type instance FI.VectorFor Age14 = UVec.Vector
F.declareColumn "Age14C" ''Age14

age14FromAge5F :: DT.Age5F -> [Age14]
age14FromAge5F DT.A5F_Under18 = [A14_Under5, A14_5To9, A14_10To14, A14_15To17]
age14FromAge5F DT.A5F_18To24 = [A14_18To19, A14_20To24]
age14FromAge5F DT.A5F_25To44 = [A14_25To29, A14_30To34, A14_35To44]
age14FromAge5F DT.A5F_45To64 = [A14_45To54, A14_55To64]
age14FromAge5F DT.A5F_65AndOver = [A14_65To74, A14_75To84, A14_85AndOver]

age14ToAge5F :: Age14 -> DT.Age5F
age14ToAge5F A14_Under5 = DT.A5F_Under18
age14ToAge5F A14_5To9 = DT.A5F_Under18
age14ToAge5F A14_10To14 = DT.A5F_Under18
age14ToAge5F A14_15To17 = DT.A5F_Under18
age14ToAge5F A14_18To19 = DT.A5F_18To24
age14ToAge5F A14_20To24 = DT.A5F_18To24
age14ToAge5F A14_25To29 = DT.A5F_25To44
age14ToAge5F A14_30To34 = DT.A5F_25To44
age14ToAge5F A14_35To44 = DT.A5F_25To44
age14ToAge5F A14_45To54 = DT.A5F_45To64
age14ToAge5F A14_55To64 = DT.A5F_45To64
age14ToAge5F A14_65To74 = DT.A5F_65AndOver
age14ToAge5F A14_75To84 = DT.A5F_65AndOver
age14ToAge5F A14_85AndOver = DT.A5F_65AndOver

age14ToAge6 :: Age14 -> DT.Age6
age14ToAge6 A14_Under5 = DT.A6_Under18
age14ToAge6 A14_5To9 = DT.A6_Under18
age14ToAge6 A14_10To14 = DT.A6_Under18
age14ToAge6 A14_15To17 = DT.A6_Under18
age14ToAge6 A14_18To19 = DT.A6_18To24
age14ToAge6 A14_20To24 = DT.A6_18To24
age14ToAge6 A14_25To29 = DT.A6_25To34
age14ToAge6 A14_30To34 = DT.A6_25To34
age14ToAge6 A14_35To44 = DT.A6_35To44
age14ToAge6 A14_45To54 = DT.A6_45To64
age14ToAge6 A14_55To64 = DT.A6_45To64
age14ToAge6 A14_65To74 = DT.A6_65AndOver
age14ToAge6 A14_75To84 = DT.A6_65AndOver
age14ToAge6 A14_85AndOver = DT.A6_65AndOver

age14ToAge5 :: Age14 -> Maybe DT.Age5
age14ToAge5 A14_Under5 = Nothing
age14ToAge5 A14_5To9 = Nothing
age14ToAge5 A14_10To14 = Nothing
age14ToAge5 A14_15To17 = Nothing
age14ToAge5 A14_18To19 = Just DT.A5_18To24
age14ToAge5 A14_20To24 = Just DT.A5_18To24
age14ToAge5 A14_25To29 = Just DT.A5_25To34
age14ToAge5 A14_30To34 = Just DT.A5_25To34
age14ToAge5 A14_35To44 = Just DT.A5_35To44
age14ToAge5 A14_45To54 = Just DT.A5_45To64
age14ToAge5 A14_55To64 = Just DT.A5_45To64
age14ToAge5 A14_65To74 = Just DT.A5_65AndOver
age14ToAge5 A14_75To84 = Just DT.A5_65AndOver
age14ToAge5 A14_85AndOver = Just DT.A5_65AndOver


reKeyAgeBySex :: (DT.Sex, DT.Age5F) -> [(DT.Sex, Age14)]
reKeyAgeBySex (s, a) = fmap (s, ) $ age14FromAge5F a

data Citizenship = Native | Naturalized | NonCitizen  deriving stock (Show, Enum, Bounded, Eq, Ord, Array.Ix, Generic)
--instance S.Serialize Citizenship
--instance B.Binary Citizenship
instance Flat.Flat Citizenship
instance Grouping Citizenship
instance K.FiniteSet Citizenship
derivingUnbox "Citizenship"
  [t|Citizenship -> Word8|]
  [|toEnum . fromEnum|]
  [|toEnum . fromEnum|]
type instance FI.VectorFor Citizenship = UVec.Vector
--F.declareColumn "AgeACS" ''AgeACS
F.declareColumn "CitizenshipC" ''Citizenship
--type CitizenshipC = "Citizenship" F.:-> Citizenship

citizenshipFromIsCitizen :: Bool -> [Citizenship]
citizenshipFromIsCitizen True = [Native, Naturalized]
citizenshipFromIsCitizen False = [NonCitizen]

citizenshipToIsCitizen :: Citizenship -> Bool
citizenshipToIsCitizen Native = True
citizenshipToIsCitizen Naturalized = True
citizenshipToIsCitizen NonCitizen = False

-- Easiest to have a type matching the census table
data RaceEthnicity = R_White | R_Black | R_Asian | R_Other | E_Hispanic | E_WhiteNonHispanic deriving stock (Show, Enum, Bounded, Eq, Ord, Array.Ix, Generic)
instance Flat.Flat RaceEthnicity
instance Grouping RaceEthnicity
instance K.FiniteSet RaceEthnicity
derivingUnbox "RaceEthnicity"
  [t|RaceEthnicity -> Word8|]
  [|toEnum . fromEnum|]
  [|toEnum . fromEnum|]
type instance FI.VectorFor RaceEthnicity = UVec.Vector
F.declareColumn "RaceEthnicityC" ''RaceEthnicity

data Employment = E_ArmedForces | E_CivEmployed | E_CivUnemployed | E_NotInLaborForce deriving stock (Show, Enum, Bounded, Eq, Ord, Array.Ix, Generic)
instance Flat.Flat Employment
instance Grouping Employment
instance K.FiniteSet Employment
derivingUnbox "Employment"
  [t|Employment -> Word8|]
  [|toEnum . fromEnum|]
  [|toEnum . fromEnum|]
type instance FI.VectorFor Employment = UVec.Vector
F.declareColumn "EmploymentC" ''Employment

newtype NHGISPrefix = NHGISPrefix { unNHGISPrefix :: Text } deriving stock (Eq, Ord, Show)
data TableYear = TY2022 | TY2021 | TY2020 | TY2018 | TY2016 | TY2014 | TY2012

tableYear :: TableYear -> Int
tableYear TY2022 = 2022
tableYear TY2021 = 2021
tableYear TY2020 = 2020
tableYear TY2018 = 2018
tableYear TY2016 = 2016
tableYear TY2014 = 2014
tableYear TY2012 = 2012

sexByAgeByEducation ::  NHGISPrefix -> Map (DT.Sex, DT.Age5, DT.Education) Text
sexByAgeByEducation (NHGISPrefix p) =
  Map.fromList [((DT.Male, DT.A5_18To24, DT.L9), p <> "E004")
               ,((DT.Male, DT.A5_18To24, DT.L12), p <> "E005")
               ,((DT.Male, DT.A5_18To24, DT.HS), p <> "E006")
               ,((DT.Male, DT.A5_18To24, DT.SC), p <> "E007")
               ,((DT.Male, DT.A5_18To24, DT.AS), p <> "E008")
               ,((DT.Male, DT.A5_18To24, DT.BA), p <> "E009")
               ,((DT.Male, DT.A5_18To24, DT.AD), p <> "E010")
               ,((DT.Male, DT.A5_25To34, DT.L9), p <> "E012")
               ,((DT.Male, DT.A5_25To34, DT.L12), p <> "E013")
               ,((DT.Male, DT.A5_25To34, DT.HS), p <> "E014")
               ,((DT.Male, DT.A5_25To34, DT.SC), p <> "E015")
               ,((DT.Male, DT.A5_25To34, DT.AS), p <> "E016")
               ,((DT.Male, DT.A5_25To34, DT.BA), p <> "E017")
               ,((DT.Male, DT.A5_25To34, DT.AD), p <> "E018")
               ,((DT.Male, DT.A5_35To44, DT.L9), p <> "E020")
               ,((DT.Male, DT.A5_35To44, DT.L12), p <> "E021")
               ,((DT.Male, DT.A5_35To44, DT.HS), p <> "E022")
               ,((DT.Male, DT.A5_35To44, DT.SC), p <> "E023")
               ,((DT.Male, DT.A5_35To44, DT.AS), p <> "E024")
               ,((DT.Male, DT.A5_35To44, DT.BA), p <> "E025")
               ,((DT.Male, DT.A5_35To44, DT.AD), p <> "E026")
               ,((DT.Male, DT.A5_45To64, DT.L9), p <> "E028")
               ,((DT.Male, DT.A5_45To64, DT.L12), p <> "E029")
               ,((DT.Male, DT.A5_45To64, DT.HS), p <> "E030")
               ,((DT.Male, DT.A5_45To64, DT.SC), p <> "E031")
               ,((DT.Male, DT.A5_45To64, DT.AS), p <> "E032")
               ,((DT.Male, DT.A5_45To64, DT.BA), p <> "E033")
               ,((DT.Male, DT.A5_45To64, DT.AD), p <> "E034")
               ,((DT.Male, DT.A5_65AndOver, DT.L9), p <> "E036")
               ,((DT.Male, DT.A5_65AndOver, DT.L12), p <> "E037")
               ,((DT.Male, DT.A5_65AndOver, DT.HS), p <> "E038")
               ,((DT.Male, DT.A5_65AndOver, DT.SC), p <> "E039")
               ,((DT.Male, DT.A5_65AndOver, DT.AS), p <> "E040")
               ,((DT.Male, DT.A5_65AndOver, DT.BA), p <> "E041")
               ,((DT.Male, DT.A5_65AndOver, DT.AD), p <> "E042")
               ,((DT.Female, DT.A5_18To24, DT.L9), p <> "E045")
               ,((DT.Female, DT.A5_18To24, DT.L12), p <> "E046")
               ,((DT.Female, DT.A5_18To24, DT.HS), p <> "E047")
               ,((DT.Female, DT.A5_18To24, DT.SC), p <> "E048")
               ,((DT.Female, DT.A5_18To24, DT.AS), p <> "E049")
               ,((DT.Female, DT.A5_18To24, DT.BA), p <> "E050")
               ,((DT.Female, DT.A5_18To24, DT.AD), p <> "E051")
               ,((DT.Female, DT.A5_25To34, DT.L9), p <> "E053")
               ,((DT.Female, DT.A5_25To34, DT.L12), p <> "E054")
               ,((DT.Female, DT.A5_25To34, DT.HS), p <> "E055")
               ,((DT.Female, DT.A5_25To34, DT.SC), p <> "E056")
               ,((DT.Female, DT.A5_25To34, DT.AS), p <> "E057")
               ,((DT.Female, DT.A5_25To34, DT.BA), p <> "E058")
               ,((DT.Female, DT.A5_25To34, DT.AD), p <> "E059")
               ,((DT.Female, DT.A5_35To44, DT.L9), p <> "E061")
               ,((DT.Female, DT.A5_35To44, DT.L12), p <> "E062")
               ,((DT.Female, DT.A5_35To44, DT.HS), p <> "E063")
               ,((DT.Female, DT.A5_35To44, DT.SC), p <> "E064")
               ,((DT.Female, DT.A5_35To44, DT.AS), p <> "E065")
               ,((DT.Female, DT.A5_35To44, DT.BA), p <> "E066")
               ,((DT.Female, DT.A5_35To44, DT.AD), p <> "E067")
               ,((DT.Female, DT.A5_45To64, DT.L9), p <> "E069")
               ,((DT.Female, DT.A5_45To64, DT.L12), p <> "E070")
               ,((DT.Female, DT.A5_45To64, DT.HS), p <> "E071")
               ,((DT.Female, DT.A5_45To64, DT.SC), p <> "E072")
               ,((DT.Female, DT.A5_45To64, DT.AS), p <> "E073")
               ,((DT.Female, DT.A5_45To64, DT.BA), p <> "E074")
               ,((DT.Female, DT.A5_45To64, DT.AD), p <> "E075")
               ,((DT.Female, DT.A5_65AndOver, DT.L9), p <> "E077")
               ,((DT.Female, DT.A5_65AndOver, DT.L12), p <> "E078")
               ,((DT.Female, DT.A5_65AndOver, DT.HS), p <> "E079")
               ,((DT.Female, DT.A5_65AndOver, DT.SC), p <> "E080")
               ,((DT.Female, DT.A5_65AndOver, DT.AS), p <> "E081")
               ,((DT.Female, DT.A5_65AndOver, DT.BA), p <> "E082")
               ,((DT.Female, DT.A5_65AndOver, DT.AD), p <> "E083")
               ]

sexByAgeByEducationPrefix :: TableYear -> NHGISPrefix
sexByAgeByEducationPrefix TY2022 = NHGISPrefix "AQ44"
sexByAgeByEducationPrefix TY2021 = NHGISPrefix "AO4V"
sexByAgeByEducationPrefix TY2020 = NHGISPrefix "AM6L"
sexByAgeByEducationPrefix TY2018 = error "No 2018 sex by age by education data" -- NHGISPrefix "AM6L"
sexByAgeByEducationPrefix TY2016 = error "No 2016 sex by age by education data" -- NHGISPrefix "AM6L"
sexByAgeByEducationPrefix TY2014 = error "No 2014 sex by age by education data" -- NHGISPrefix "AM6L"
sexByAgeByEducationPrefix TY2012 = error "No 2012 sex by age by education data" -- NHGISPrefix "Q8Z"

sexByAgeByEmploymentPrefix :: TableYear -> RaceEthnicity -> [NHGISPrefix]
sexByAgeByEmploymentPrefix TY2022 R_White = [NHGISPrefix "ARBB"]
sexByAgeByEmploymentPrefix TY2022 R_Black = [NHGISPrefix "ARBC"]
sexByAgeByEmploymentPrefix TY2022 R_Asian = NHGISPrefix <$> ["ARBE","ARBF"] -- AAPI
sexByAgeByEmploymentPrefix TY2022 R_Other = NHGISPrefix <$> ["ARBD", "ARBG", "ARBH"]
sexByAgeByEmploymentPrefix TY2022 E_Hispanic = [NHGISPrefix "ARBJ"]
sexByAgeByEmploymentPrefix TY2022 E_WhiteNonHispanic = [NHGISPrefix "ARBI"]

sexByAgeByEmploymentPrefix TY2021 R_White = [NHGISPrefix "APGN"]
sexByAgeByEmploymentPrefix TY2021 R_Black = [NHGISPrefix "APGO"]
sexByAgeByEmploymentPrefix TY2021 R_Asian = NHGISPrefix <$> ["APGQ","APGR"] -- AAPI
sexByAgeByEmploymentPrefix TY2021 R_Other = NHGISPrefix <$> ["APGP", "APGS", "APGT"]
sexByAgeByEmploymentPrefix TY2021 E_Hispanic = [NHGISPrefix "APGV"]
sexByAgeByEmploymentPrefix TY2021 E_WhiteNonHispanic = [NHGISPrefix "APGU"]

sexByAgeByEmploymentPrefix TY2020 R_White = [NHGISPrefix "ANH9"]
sexByAgeByEmploymentPrefix TY2020 R_Black = [NHGISPrefix "ANIA"]
sexByAgeByEmploymentPrefix TY2020 R_Asian = NHGISPrefix <$> ["ANIC", "ANID"]
sexByAgeByEmploymentPrefix TY2020 R_Other = NHGISPrefix <$> ["ANIB", "ANIE", "ANIF"]
sexByAgeByEmploymentPrefix TY2020 E_Hispanic = [NHGISPrefix "ANIH"]
sexByAgeByEmploymentPrefix TY2020 E_WhiteNonHispanic = [NHGISPrefix "ANIG"]
sexByAgeByEmploymentPrefix TY2018 R_White = [NHGISPrefix "AKJD"]
sexByAgeByEmploymentPrefix TY2018 R_Black = [NHGISPrefix "AKJE"]
sexByAgeByEmploymentPrefix TY2018 R_Asian = [NHGISPrefix "AKJG"]
sexByAgeByEmploymentPrefix TY2018 R_Other = NHGISPrefix <$> ["AKJF", "AKJH", "AKJI", "AKJJ"]
sexByAgeByEmploymentPrefix TY2018 E_Hispanic = [NHGISPrefix "AKJL"]
sexByAgeByEmploymentPrefix TY2018 E_WhiteNonHispanic = [NHGISPrefix "AKJK"]
sexByAgeByEmploymentPrefix TY2016 R_White = [NHGISPrefix "AGOJ"]
sexByAgeByEmploymentPrefix TY2016 R_Black = [NHGISPrefix "AGOK"]
sexByAgeByEmploymentPrefix TY2016 R_Asian = [NHGISPrefix "AGOM"]
sexByAgeByEmploymentPrefix TY2016 R_Other = NHGISPrefix <$> ["AGOL", "AGON", "AGOO", "AGOP"]
sexByAgeByEmploymentPrefix TY2016 E_Hispanic = [NHGISPrefix "AGOR"]
sexByAgeByEmploymentPrefix TY2016 E_WhiteNonHispanic = [NHGISPrefix "AGOQ"]
sexByAgeByEmploymentPrefix TY2014 R_White = [NHGISPrefix "ABWZ"]
sexByAgeByEmploymentPrefix TY2014 R_Black = [NHGISPrefix "ABW0"]
sexByAgeByEmploymentPrefix TY2014 R_Asian = [NHGISPrefix "ABWZ"]
sexByAgeByEmploymentPrefix TY2014 R_Other = NHGISPrefix <$> ["ABW1", "ABW3", "ABW4", "ABW5"]
sexByAgeByEmploymentPrefix TY2014 E_Hispanic = [NHGISPrefix "ABW7"]
sexByAgeByEmploymentPrefix TY2014 E_WhiteNonHispanic = [NHGISPrefix "ABW6"]
sexByAgeByEmploymentPrefix TY2012 R_White = [NHGISPrefix "REA"]
sexByAgeByEmploymentPrefix TY2012 R_Black = [NHGISPrefix "REB"]
sexByAgeByEmploymentPrefix TY2012 R_Asian = [NHGISPrefix "RED"]
sexByAgeByEmploymentPrefix TY2012 R_Other = NHGISPrefix <$> ["REC", "REE", "REF", "REG"]
sexByAgeByEmploymentPrefix TY2012 E_Hispanic = [NHGISPrefix "REI"]
sexByAgeByEmploymentPrefix TY2012 E_WhiteNonHispanic = [NHGISPrefix "REH"]

data EmpAge = EA_16To64 | EA_65AndOver deriving stock (Show, Enum, Bounded, Eq, Ord, Array.Ix, Generic)
derivingUnbox "EmpAge"
  [t|EmpAge -> Word8|]
  [|toEnum . fromEnum|]
  [|toEnum . fromEnum|]
type instance FI.VectorFor EmpAge = UVec.Vector
F.declareColumn "EmpAgeC" ''EmpAge
--type EmpAgeC = "EmpAge" F.:-> EmpAge

sexByAgeByEmployment :: NHGISPrefix -> Map (DT.Sex, EmpAge, Employment) Text
sexByAgeByEmployment (NHGISPrefix p) =
  Map.fromList [((DT.Male, EA_16To64, E_ArmedForces), p <> "E005")
               ,((DT.Male, EA_16To64, E_CivEmployed), p <> "E007")
               ,((DT.Male, EA_16To64, E_CivUnemployed), p <> "E008")
               ,((DT.Male, EA_16To64, E_NotInLaborForce), p <> "E009")
               ,((DT.Female, EA_16To64, E_ArmedForces), p <> "E018")
               ,((DT.Female, EA_16To64, E_CivEmployed), p <> "E020")
               ,((DT.Female, EA_16To64, E_CivUnemployed), p <> "E021")
               ,((DT.Female, EA_16To64, E_NotInLaborForce), p <> "E022")
               ,((DT.Male, EA_65AndOver, E_CivEmployed), p <> "E012")
               ,((DT.Male, EA_65AndOver, E_CivUnemployed), p <> "E013")
               ,((DT.Male, EA_65AndOver, E_NotInLaborForce), p <> "E014")
               ,((DT.Female, EA_65AndOver, E_CivEmployed), p <> "E025")
               ,((DT.Female, EA_65AndOver, E_CivUnemployed), p <> "E026")
               ,((DT.Female, EA_65AndOver, E_NotInLaborForce), p <> "E027")
               ]

sexByAgePrefix :: TableYear -> RaceEthnicity -> [NHGISPrefix]
sexByAgePrefix TY2022 R_White = [NHGISPrefix "AQYH"]
sexByAgePrefix TY2022 R_Black = [NHGISPrefix "AQYI"]
sexByAgePrefix TY2022 R_Asian = NHGISPrefix <$> ["AQYK", "AQYL"] -- AAPI
sexByAgePrefix TY2022 R_Other = NHGISPrefix <$> ["AQYJ", "AQYM", "AQYN"]
sexByAgePrefix TY2022 E_Hispanic = [NHGISPrefix "AQYP"]
sexByAgePrefix TY2022 E_WhiteNonHispanic = [NHGISPrefix "AQYO"]
sexByAgePrefix TY2021 R_White = [NHGISPrefix "AOYA"]
sexByAgePrefix TY2021 R_Black = [NHGISPrefix "AOYB"]
sexByAgePrefix TY2021 R_Asian = NHGISPrefix <$> ["AOYD", "AOYE"] -- AAPI
sexByAgePrefix TY2021 R_Other = NHGISPrefix <$> ["AOYC", "AOYF", "AOYG"]
sexByAgePrefix TY2021 E_Hispanic = [NHGISPrefix "AOYI"]
sexByAgePrefix TY2021 E_WhiteNonHispanic = [NHGISPrefix "AOYH"]
sexByAgePrefix TY2020 R_White = [NHGISPrefix "AMZ0"]
sexByAgePrefix TY2020 R_Black = [NHGISPrefix "AMZ1"]
sexByAgePrefix TY2020 R_Asian = NHGISPrefix <$> ["AMZ3",  "AMZ4"]
sexByAgePrefix TY2020 R_Other = NHGISPrefix <$> ["AMZ2", "AMZ5", "AMZ6"]
sexByAgePrefix TY2020 E_Hispanic = [NHGISPrefix "AMZ8"]
sexByAgePrefix TY2020 E_WhiteNonHispanic = [NHGISPrefix "AMZ7"]
sexByAgePrefix TY2018 R_White = [NHGISPrefix "AJ6O"]
sexByAgePrefix TY2018 R_Black = [NHGISPrefix "AJ6P"]
sexByAgePrefix TY2018 R_Asian = [NHGISPrefix "AJ6R"]
sexByAgePrefix TY2018 R_Other = NHGISPrefix <$> ["AJ6Q", "AJ6S", "AJ6T", "AJ6U"]
sexByAgePrefix TY2018 E_Hispanic = [NHGISPrefix "AJ6W"]
sexByAgePrefix TY2018 E_WhiteNonHispanic = [NHGISPrefix "AJ6V"]
sexByAgePrefix TY2016 R_White = [NHGISPrefix "AGBT"]
sexByAgePrefix TY2016 R_Black = [NHGISPrefix "AGBU"]
sexByAgePrefix TY2016 R_Asian = [NHGISPrefix "AGBW"]
sexByAgePrefix TY2016 R_Other = NHGISPrefix <$> ["AGBV", "AGBX", "AGBY", "AGBZ"]
sexByAgePrefix TY2016 E_Hispanic = [NHGISPrefix "AGB1"]
sexByAgePrefix TY2016 E_WhiteNonHispanic = [NHGISPrefix "AGB0"]
sexByAgePrefix TY2014 R_White = [NHGISPrefix "ABK1"]
sexByAgePrefix TY2014 R_Black = [NHGISPrefix "ABK2"]
sexByAgePrefix TY2014 R_Asian = [NHGISPrefix "ABK4"]
sexByAgePrefix TY2014 R_Other = NHGISPrefix <$> ["ABK3", "ABK5", "ABK6", "ABK7"]
sexByAgePrefix TY2014 E_Hispanic = [NHGISPrefix "ABK9"]
sexByAgePrefix TY2014 E_WhiteNonHispanic = [NHGISPrefix "ABK8"]
sexByAgePrefix TY2012 R_White = [NHGISPrefix "Q2C"]
sexByAgePrefix TY2012 R_Black = [NHGISPrefix "Q2D"]
sexByAgePrefix TY2012 R_Asian = [NHGISPrefix "Q2F"]
sexByAgePrefix TY2012 R_Other = NHGISPrefix <$> ["Q2E", "Q2G", "Q2H", "Q2I"]
sexByAgePrefix TY2012 E_Hispanic = [NHGISPrefix "Q2K"]
sexByAgePrefix TY2012 E_WhiteNonHispanic = [NHGISPrefix "Q2J"]


sexByAge :: NHGISPrefix -> Map (DT.Sex, Age14) Text
sexByAge (NHGISPrefix p) =
  Map.fromList [((DT.Male, A14_Under5), p <> "E003")
               ,((DT.Male, A14_5To9), p <> "E004")
               ,((DT.Male, A14_10To14), p <> "E005")
               ,((DT.Male, A14_15To17), p <> "E006")
               ,((DT.Male, A14_18To19), p <> "E007")
               ,((DT.Male, A14_20To24), p <> "E008")
               ,((DT.Male, A14_25To29), p <> "E009")
               ,((DT.Male, A14_30To34), p <> "E010")
               ,((DT.Male, A14_35To44), p <> "E011")
               ,((DT.Male, A14_45To54), p <> "E012")
               ,((DT.Male, A14_55To64), p <> "E013")
               ,((DT.Male, A14_65To74), p <> "E014")
               ,((DT.Male, A14_75To84), p <> "E015")
               ,((DT.Male, A14_85AndOver), p <> "E016")
               ,((DT.Female, A14_Under5), p <> "E018")
               ,((DT.Female, A14_5To9), p <> "E019")
               ,((DT.Female, A14_10To14), p <> "E020")
               ,((DT.Female, A14_15To17), p <> "E021")
               ,((DT.Female, A14_18To19), p <> "E022")
               ,((DT.Female, A14_20To24), p <> "E023")
               ,((DT.Female, A14_25To29), p <> "E024")
               ,((DT.Female, A14_30To34), p <> "E025")
               ,((DT.Female, A14_35To44), p <> "E026")
               ,((DT.Female, A14_45To54), p <> "E027")
               ,((DT.Female, A14_55To64), p <> "E028")
               ,((DT.Female, A14_65To74), p <> "E029")
               ,((DT.Female, A14_75To84), p <> "E030")
               ,((DT.Female, A14_85AndOver), p <> "E031")
               ]

sexByCitizenshipPrefix :: TableYear -> RaceEthnicity -> [NHGISPrefix]
sexByCitizenshipPrefix TY2022 R_White = [NHGISPrefix "AQY7"]
sexByCitizenshipPrefix TY2022 R_Black = [NHGISPrefix "AQY8"]
sexByCitizenshipPrefix TY2022 R_Asian = NHGISPrefix <$> ["AQZA", "AQZB"]
sexByCitizenshipPrefix TY2022 R_Other = NHGISPrefix <$> ["AQY9", "AQZC", "AQZD"]
sexByCitizenshipPrefix TY2022 E_Hispanic = [NHGISPrefix "AQZF"]
sexByCitizenshipPrefix TY2022 E_WhiteNonHispanic = [NHGISPrefix "AQZE"]

sexByCitizenshipPrefix TY2021 R_White = [NHGISPrefix "AOYY"]
sexByCitizenshipPrefix TY2021 R_Black = [NHGISPrefix "AOYZ"]
sexByCitizenshipPrefix TY2021 R_Asian = NHGISPrefix <$> ["AOY1", "AOY2"]
sexByCitizenshipPrefix TY2021 R_Other = NHGISPrefix <$> ["AOY0", "AOY3", "AOY4"]
sexByCitizenshipPrefix TY2021 E_Hispanic = [NHGISPrefix "AOY6"]
sexByCitizenshipPrefix TY2021 E_WhiteNonHispanic = [NHGISPrefix "AOY5"]

sexByCitizenshipPrefix TY2020 R_White = [NHGISPrefix "AM0O"]
sexByCitizenshipPrefix TY2020 R_Black = [NHGISPrefix "AM0P"]
sexByCitizenshipPrefix TY2020 R_Asian = NHGISPrefix <$> ["AM0R", "AM0S"]
sexByCitizenshipPrefix TY2020 R_Other = NHGISPrefix <$> ["AM0Q", "AM0T", "AM0U"]
sexByCitizenshipPrefix TY2020 E_Hispanic = [NHGISPrefix "AM0W"]
sexByCitizenshipPrefix TY2020 E_WhiteNonHispanic = [NHGISPrefix "AM0V"]

sexByCitizenshipPrefix TY2018 R_White = [NHGISPrefix "AJ7C"]
sexByCitizenshipPrefix TY2018 R_Black = [NHGISPrefix "AJ7D"]
sexByCitizenshipPrefix TY2018 R_Asian = [NHGISPrefix "AJ7F"]
sexByCitizenshipPrefix TY2018 R_Other = NHGISPrefix <$> ["AJ7E", "AJ7G", "AJ7H", "AJ7I"]
sexByCitizenshipPrefix TY2018 E_Hispanic = [NHGISPrefix "AJ7K"]
sexByCitizenshipPrefix TY2018 E_WhiteNonHispanic = [NHGISPrefix "AJ7J"]

sexByCitizenshipPrefix TY2016 R_White = [NHGISPrefix "AGCH"]
sexByCitizenshipPrefix TY2016 R_Black = [NHGISPrefix "AGCI"]
sexByCitizenshipPrefix TY2016 R_Asian = [NHGISPrefix "AGCK"]
sexByCitizenshipPrefix TY2016 R_Other = NHGISPrefix <$> ["AGCJ", "AGCL", "AGCM", "AGCN"]
sexByCitizenshipPrefix TY2016 E_Hispanic = [NHGISPrefix "AGCP"]
sexByCitizenshipPrefix TY2016 E_WhiteNonHispanic = [NHGISPrefix "AGCO"]

sexByCitizenshipPrefix TY2014 R_White = [NHGISPrefix "ABLM"]
sexByCitizenshipPrefix TY2014 R_Black = [NHGISPrefix "ABLN"]
sexByCitizenshipPrefix TY2014 R_Asian = [NHGISPrefix "ABLP"]
sexByCitizenshipPrefix TY2014 R_Other = NHGISPrefix <$> ["ABLO", "ABLQ", "ABLR", "ABLS"]
sexByCitizenshipPrefix TY2014 E_Hispanic = [NHGISPrefix "ABLU"]
sexByCitizenshipPrefix TY2014 E_WhiteNonHispanic = [NHGISPrefix "ABLT"]

sexByCitizenshipPrefix TY2012 R_White = [NHGISPrefix "Q20"]
sexByCitizenshipPrefix TY2012 R_Black = [NHGISPrefix "Q21"]
sexByCitizenshipPrefix TY2012 R_Asian = [NHGISPrefix "Q23"]
sexByCitizenshipPrefix TY2012 R_Other = NHGISPrefix <$> ["Q22", "Q24", "Q25", "Q26"]
sexByCitizenshipPrefix TY2012 E_Hispanic = [NHGISPrefix "Q28"]
sexByCitizenshipPrefix TY2012 E_WhiteNonHispanic = [NHGISPrefix "Q27"]

sexByCitizenship :: NHGISPrefix -> Map (DT.Sex, Citizenship) Text
sexByCitizenship (NHGISPrefix p) = Map.fromList [((DT.Male, Native), p <> "E009")
                                                ,((DT.Male, Naturalized), p <> "E011")
                                                ,((DT.Male, NonCitizen), p <> "E012")
                                                ,((DT.Female, Native), p <> "E020")
                                                ,((DT.Female, Naturalized), p <> "E022")
                                                ,((DT.Female, NonCitizen), p <> "E023")
                                                ]

sexByEducationPrefix :: TableYear -> RaceEthnicity -> [NHGISPrefix]
sexByEducationPrefix TY2022 R_White = [NHGISPrefix "AQ45"]
sexByEducationPrefix TY2022 R_Black = [NHGISPrefix "AQ46"]
sexByEducationPrefix TY2022 R_Asian = NHGISPrefix <$> ["AQ48", "AQ49"]
sexByEducationPrefix TY2022 R_Other = NHGISPrefix <$> ["AQ47", "AQ5A", "AQ5B"]
sexByEducationPrefix TY2022 E_Hispanic = [NHGISPrefix "AQ5D"]
sexByEducationPrefix TY2022 E_WhiteNonHispanic = [NHGISPrefix "AQ5C"]

sexByEducationPrefix TY2021 R_White = [NHGISPrefix "APFZ"]
sexByEducationPrefix TY2021 R_Black = [NHGISPrefix "APF0"]
sexByEducationPrefix TY2021 R_Asian = NHGISPrefix <$> ["APF2", "APF3"]
sexByEducationPrefix TY2021 R_Other = NHGISPrefix <$> ["APF1", "APF4", "APF5"]
sexByEducationPrefix TY2021 E_Hispanic = [NHGISPrefix "APF7"]
sexByEducationPrefix TY2021 E_WhiteNonHispanic = [NHGISPrefix "APF6"]

sexByEducationPrefix TY2020 R_White = [NHGISPrefix "ANHL"]
sexByEducationPrefix TY2020 R_Black = [NHGISPrefix "ANHM"]
sexByEducationPrefix TY2020 R_Asian = [NHGISPrefix "ANHO"]
sexByEducationPrefix TY2020 R_Other = NHGISPrefix <$> ["ANHN", "ANHP", "ANHQ", "ANHR"]
sexByEducationPrefix TY2020 E_Hispanic = [NHGISPrefix "ANHT"]
sexByEducationPrefix TY2020 E_WhiteNonHispanic = [NHGISPrefix "ANHS"]

sexByEducationPrefix TY2018 R_White = [NHGISPrefix "AKDA"]
sexByEducationPrefix TY2018 R_Black = [NHGISPrefix "AKDB"]
sexByEducationPrefix TY2018 R_Asian = [NHGISPrefix "AKDD"]
sexByEducationPrefix TY2018 R_Other = NHGISPrefix <$> ["AKDC", "AKDE", "AKDF", "AKDG"]
sexByEducationPrefix TY2018 E_Hispanic = [NHGISPrefix "AKDI"]
sexByEducationPrefix TY2018 E_WhiteNonHispanic = [NHGISPrefix "AKDH"]

sexByEducationPrefix TY2016 R_White = [NHGISPrefix "AGIF"]
sexByEducationPrefix TY2016 R_Black = [NHGISPrefix "AGIG"]
sexByEducationPrefix TY2016 R_Asian = [NHGISPrefix "AGII"]
sexByEducationPrefix TY2016 R_Other = NHGISPrefix <$> ["AGIH", "AGIJ", "AGIK", "AGIL"]
sexByEducationPrefix TY2016 E_Hispanic = [NHGISPrefix "AGIN"]
sexByEducationPrefix TY2016 E_WhiteNonHispanic = [NHGISPrefix "AGIM"]

sexByEducationPrefix TY2014 R_White = [NHGISPrefix "ABRO"]
sexByEducationPrefix TY2014 R_Black = [NHGISPrefix "ABRP"]
sexByEducationPrefix TY2014 R_Asian = [NHGISPrefix "ABRR"]
sexByEducationPrefix TY2014 R_Other = NHGISPrefix <$> ["ABRQ", "ABRS", "ABRT", "ABRU"]
sexByEducationPrefix TY2014 E_Hispanic = [NHGISPrefix "ABRW"]
sexByEducationPrefix TY2014 E_WhiteNonHispanic = [NHGISPrefix "ABRV"]

sexByEducationPrefix TY2012 R_White = [NHGISPrefix "Q80"]
sexByEducationPrefix TY2012 R_Black = [NHGISPrefix "Q81"]
sexByEducationPrefix TY2012 R_Asian = [NHGISPrefix "Q83"]
sexByEducationPrefix TY2012 R_Other = NHGISPrefix <$> ["Q82", "Q84", "Q85", "Q86"]
sexByEducationPrefix TY2012 E_Hispanic = [NHGISPrefix "Q88"]
sexByEducationPrefix TY2012 E_WhiteNonHispanic = [NHGISPrefix "Q87"]

sexByEducation :: NHGISPrefix -> Map (DT.Sex, DT.Education4) Text
sexByEducation (NHGISPrefix p) = Map.fromList [((DT.Male, DT.E4_NonHSGrad), p <> "E003")
                                              ,((DT.Male, DT.E4_HSGrad), p <> "E004")
                                              ,((DT.Male, DT.E4_SomeCollege), p <> "E005")
                                              ,((DT.Male, DT.E4_CollegeGrad), p <> "E006")
                                              ,((DT.Female, DT.E4_NonHSGrad), p <> "E008")
                                              ,((DT.Female, DT.E4_HSGrad), p <> "E009")
                                              ,((DT.Female, DT.E4_SomeCollege), p <> "E010")
                                              ,((DT.Female, DT.E4_CollegeGrad), p <> "E011")
                                              ]

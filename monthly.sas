

%macro NullSymbol(sym);
 %if (not %symexist(sym) or "&sym"="") %then %do;
	%put Symbol seems to be null;
 %end;
 %else %put "Symbol &sym resolves to &sym."; *a replacement for symbolgen so you can safely always have options nosymbolgen;
%mend NullSymbol;

%macro lst(ds, var=);                                                                                                                        
  %local dsid cnt rc x;
  %global exist;                                                                                                                 
  %let x=;                                                                                                                              
  %let dsid=%sysfunc(open(&ds));                                                                                                       
  %let cnt=%sysfunc(attrn(&dsid,nvars));                                                                                                
   %do i = 1 %to &cnt;                                                                                                                  
    %let x=&x %sysfunc(varname(&dsid,&i));                                                                                                          
   %end;                                                                                                                                
  %let exist=%eval(%sysfunc(find(&x,&var))>0);                                                                                                                                      
  %let rc=%sysfunc(close(&dsid));    
      %let not=;
      %if %eval(&exist=0) %then %let not=NOT; 
      %put The variable named &var does &not exist on dataset=&ds, exist=&exist;   
                                                                                                                                  
%mend lst; 

/***************************************************** Module 1 - Model Building Macro *****************************************************/
/*******************************************************************************************************************************************/
/******************************  This slicing logic assumes full data, so that future values of covariate(s)  ******************************/
/******************************   (whether forecasted or actual) are available 24 obs ahead. Reports accuracy ******************************/
/*******************************************************************************************************************************************/

options mprint mlogic symbolgen source notes;
%macro module1_build(       InputDataset           =, 
							ForecastSeries         =,
							DateVariable           =,
							PredictedTemperature   =,
							HistoricalObservations =,
							ProblemSpeed           =24,
							ForecastArchitecture   =,
							Model                  =trend &m. L_1 T1_0 &d.*&h. T1_0*&h. T2_0*&h. T3_0*&h. T1_1*&h. T2_1*&h. T3_1*&h. T1_0*&m. T2_0*&m. T3_0*&m. T1_1*&m. T2_1*&m. T3_1*&m. L_1*&h. L_1*&m.,

                            /* hidden for dev */
                            h=HOURofDay, d=DAYofWeek, m=MONTHofYear);
data _null_;
set &ForecastArchitecture.;
*Currently assumed ForecastWindow, ForecastStart and ForecastEnd are numeric numbers of observations;
call symputx("ForecastWindow", ForecastWindow,"g"); 
call symputx("ForecastStart",  From,"g");
call symputx("ForecastEnd",    To,"g");
call symputx("Iterations",     Iterations,"g");
run;
%local RoleVariable;

%do IterationLoop=&Iterations. %to 1 %by -1;

			%local indata;   *it may be possible to do this outside the loop but each iteration does need this idea done....;
			%let indata=atemprenameofindat;
			data &indata;
				set &InputDataset(rename=(&PredictedTemperature=T1_0 &DateVariable=datetime &ForecastSeries=L_0 /*&RoleVariable=role*/) );	
			    T2_0=T1_0**2;
				T3_0=T1_0**3;
				T1_1=lag(T1_0);
				T2_1=T1_1**2;
				T3_1=T1_1**3;
				L_1=lag(L_0);
				L_2=lag(L_1);
				temp_diff=dif(T1_0);
			run;

			proc sql; 
			select count(*) 
			 into : inputnumobs 
			 from &indata; 
			quit;

			*knock back 24 obs;
			%let train2_limit_Nminus24=%eval(&inputnumobs - (&IterationLoop * &ForecastWindow.));
			%put train2_limit_Nminus24=&train2_limit_Nminus24;

			*forking train/hold, train2 will become the main working dataset;
			data train2 hold1; 
			set &indata; 
			if _n_ <= &train2_limit_Nminus24 then output train2; 
			else output hold1; 
			run;

			%do i= 1 %to &ForecastWindow. %by 1; 

					*Use a macro variable to point to the obsnum that is the next in line to be forecasted;
				    **In a multilag GLM this is the start of the "ex ante gray period longjump"; 
					%let iteration_obs=%eval(&train2_limit_Nminus24 + &i); 
					%put iteration_obs=&iteration_obs;

					data hold2_single;
						set &indata;
						if _n_=&iteration_obs then output;
					run;

					**IMPORTANT: we have to recalculate the lags of load (L_1 etc, ex. L_20) with their predicted values; 
					DATA getastep_prediction;
						SET train2(IN=__ORIG) hold2_single;
						__FLAG=__ORIG; * you do need this to pass info downstream;
						*recalc lags or they will be stale i.e. info leaks;
						L_1=lag(L_0);
						L_2=lag(L_1);
						*blank  out VoI for that last set ob;
						if not __FLAG then L_0=.;
					RUN;

					*model and output the predictions; 
					PROC GLM DATA=getastep_prediction
							PLOTS=NONE NOPRINT 
						;
						CLASS &d. &h. &m.;
						MODEL L_0 =
						&MODEL.
						;
						RUN;
						OUTPUT OUT= predict1_onestepiter (WHERE=(NOT __FLAG))
							PREDICTED=predicted_Load ;
						RUN;
					QUIT;


					data predict1_onestepiter; * in place, shift that variable predicted_Load over to the target &ForecastSeries. (its all in the names, at this point in the flow L_0);
					set predict1_onestepiter;
					L_0 = predicted_Load;
					drop predicted_Load __FLAG;
					run; 

					*train2 is the working DS, append to there (closed loop) i.e. look there for predicteds theyll be obs > amper train2_limit_Nminus24; 
					%put APPENDINGggggggggggg; 
					proc append base=train2 data=predict1_onestepiter; run; quit;

			%end;

			data train3;
			set train2;
			if _n_ > &train2_limit_Nminus24 then output;
			run;



%end; *iterate=ampIterations;

%mend module1_build;


 /****************************************************  Module No ****************************************************
 
			*getting accuracy measures, namely RMSE, with SQL;
			proc sql;
			               create table working_holdact as
						    select actual.*, forec.L_0 as predicted_Load label="Predicted Forecasts of &ForecastSeries."
							  from hold1 as actual, train3 as forec
							   where actual.datetime=forec.datetime  
					;
				create table SingletonResult as
			  select sqrt(avg(se)) as rmse, sqrt(avg(sa)) as rmsa, avg(abs(L_0-predicted_Load)/L_0) as mape, (calculated rmse)/(calculated rmsa) as prmse_a
			   from 
				  (  select *, (L_0-predicted_Load)**2 as se, (L_0)**2 as sa
					  from working_holdact
				   )
			  ;
			quit;

 */
 
 

/************************************************ Module 3 - Architecture Building Macro *************************************************/
/*****************************************************************************************************************************************/
/******************************  Creates an architecture dataset for use by MODULE ONE.  Default is one     ******************************/
/******************************   iteration of 24 obs (corr to 24 hours?, to end of data availability.      ******************************/
/*****************************************************************************************************************************************/
%macro module3_arch(iter=1,InputDataset=);
 *The macro variable iter is the number of 24-hour periods to run ex ante DynReg for;

*count observations in the input dataset;
 %local inputnumobs;
proc sql; 
select count(*) 
 into : inputnumobs 
 from &InputDataset; 
quit;
*Currently the architecture dataset specifies essentially only the "ForecastWindow" which is the number
 of observations in each run of the system (e.g. 24 for day-ahead ELF) and the number of times to do so
 (e.g. 24 by 3 will go back a total of 144 observations and give 3 sets of 24-obs forecasts, with accuracy and graphs)
 Currently it is assumed that no overlap or chunking is done, and that in the end all data will get used (i.e. the last run
 will get the last data point).  Other forms of input are planned but not yet implemented.;
data architect;
ForecastWindow=24;
From=&inputnumobs- (24 * &iter.);
To=&inputnumobs;  *currently To always the end of the data, no need to spend time on this now;
Iterations=&iter.;
run;
%mend module3_arch;


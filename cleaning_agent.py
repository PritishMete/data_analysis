import pandas as pd
import traceback
# Import your specific LLM client here (e.g., from ai_engine import llm_generate)

class AgenticBacktracker:
    def __init__(self, llm_client):
        self.llm = llm_client

    def _generate_imputation_code(self, columns: list, target_column: str, sample_data: dict) -> str:
        """
        Prompts the AI to deduce the mathematical relationship and generate Pandas code.
        """
        prompt = f"""
        You are an expert AI Data Analyst. You are given a pandas DataFrame named `df`.
        
        Columns: {columns}
        Sample Data: {sample_data}
        Target Column with Missing Values: '{target_column}'
        
        Task:
        1. Deduce the mathematical relationship between '{target_column}' and the other columns based on their semantic names. 
           (e.g., if 'discount_percentage' is missing, deduce it algebraically from qty, price, and total_price).
        2. Write Python Pandas code to fill ONLY the missing (NaN) values in `df['{target_column}']`.
        3. Use vectorised Pandas operations (e.g., `df.loc[df['{target_column}'].isnull(), '{target_column}'] = ...`).
        
        Constraints:
        - Return ONLY valid, executable Python code. 
        - Do not include markdown formatting, explanations, or ```python blocks.
        - Do not overwrite existing valid data in the target column.
        """
        
        # Replace this with your actual LLM call (Gemini/Vertex AI)
        raw_response = self.llm.generate(prompt)
        
        # Clean up the response just in case the LLM outputs markdown
        clean_code = raw_response.replace("```python", "").replace("```", "").strip()
        return clean_code

    def apply_dynamic_backtrack(self, df: pd.DataFrame, target_column: str) -> tuple[pd.DataFrame, bool, str]:
        """
        Executes the AI-generated code safely on the DataFrame.
        """
        if target_column not in df.columns:
            return df, False, f"Column {target_column} not found in dataset."

        columns = list(df.columns)
        # Pass a small sample so the AI understands the data scale (e.g., percentages as 0.10 vs 10)
        sample_data = df.head(3).to_dict(orient="records") 
        
        generated_code = self._generate_imputation_code(columns, target_column, sample_data)
        
        # Safe execution environment restricted to pandas
        execution_env = {
            'pd': pd,
            'df': df.copy() # Operate on a copy to prevent partial mutations on failure
        }
        
        try:
            exec(generated_code, {}, execution_env)
            updated_df = execution_env['df']
            return updated_df, True, "Successfully backtracked and filled missing values."
        except Exception as e:
            error_trace = traceback.format_exc()
            return df, False, f"AI generated invalid code. Error: {str(e)}\nCode:\n{generated_code}"
